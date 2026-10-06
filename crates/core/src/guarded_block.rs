//! Idempotent insertion and removal of a marker-delimited block inside a file
//! the user also edits by hand (`~/.zprofile`, `~/.bash_profile`,
//! `config.fish`).
//!
//! Deliberately a pure `&str -> String` transform. It is the most dangerous
//! operation in the app — it rewrites a file that can break the user's login
//! shell — so it does no I/O at all and every edge case is reachable from a
//! test.

use crate::types::Error;
use std::ops::RangeInclusive;

/// Detection matches on these prefixes rather than the full marker text, so a
/// future version that changes the trailing note can still find — and
/// migrate — a block written by v1.
pub const BEGIN_PREFIX: &str = "# >>> hyperenv managed block";
pub const END_PREFIX: &str = "# <<< hyperenv managed block";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Markers {
    pub begin: String,
    pub end: String,
}

impl Markers {
    /// The same markers as the Swift app, so a `~/.zprofile` written by 1.x is
    /// still recognised.
    pub fn v1() -> Self {
        Self {
            begin: format!("{BEGIN_PREFIX} v1 >>> (do not edit)"),
            end: format!("{END_PREFIX} v1 <<<"),
        }
    }
}

// ── Line model ───────────────────────────────────────────────────────────────

/// A file decomposed into lines plus the two properties that must survive a
/// round trip: which terminator it uses, and whether it ended with one. Losing
/// either would show up as a whole-file diff in the user's dotfiles repo.
#[derive(Debug, Clone, PartialEq, Eq)]
struct LineModel {
    lines: Vec<String>,
    uses_crlf: bool,
    has_trailing_newline: bool,
}

impl LineModel {
    fn parse(content: &str) -> Self {
        let mut normalized = String::with_capacity(content.len());
        let mut saw_crlf = false;
        let mut chars = content.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\r' {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                    saw_crlf = true;
                }
                // A lone CR counts as a line break too.
                normalized.push('\n');
            } else {
                normalized.push(c);
            }
        }
        let has_trailing_newline = normalized.ends_with('\n');
        if has_trailing_newline {
            normalized.pop();
        }
        let lines = if normalized.is_empty() && !has_trailing_newline {
            Vec::new()
        } else {
            normalized.split('\n').map(str::to_owned).collect()
        };
        Self {
            lines,
            uses_crlf: saw_crlf,
            has_trailing_newline,
        }
    }

    fn render(&self) -> String {
        let terminator = if self.uses_crlf { "\r\n" } else { "\n" };
        let mut out = self.lines.join(terminator);
        if self.has_trailing_newline {
            out.push_str(terminator);
        }
        out
    }
}

fn is_blank(line: &str) -> bool {
    line.trim_matches([' ', '\t']).is_empty()
}

// ── Span location ────────────────────────────────────────────────────────────

/// Locates the managed block, or fails if the file is in a state where
/// guessing could destroy user content.
///
/// Matching is exact-prefix on a trimmed line, so a marker quoted inside a
/// user's own comment (`# see the "# >>> hyperenv" block`) does not count.
fn find_span(lines: &[String], path: &str) -> Result<Option<RangeInclusive<usize>>, Error> {
    let trimmed = |l: &String| l.trim_matches([' ', '\t']).to_owned();
    let begins: Vec<usize> = (0..lines.len())
        .filter(|&i| trimmed(&lines[i]).starts_with(BEGIN_PREFIX))
        .collect();
    let ends: Vec<usize> = (0..lines.len())
        .filter(|&i| trimmed(&lines[i]).starts_with(END_PREFIX))
        .collect();

    let fail = |detail: String| Error::UnbalancedMarkers {
        path: path.to_owned(),
        detail,
    };

    match (begins.len(), ends.len()) {
        (0, 0) => Ok(None),
        (1, 1) if ends[0] > begins[0] => Ok(Some(begins[0]..=ends[0])),
        (1, 1) => Err(fail(format!(
            "the end marker on line {} comes before the begin marker on line {}",
            ends[0] + 1,
            begins[0] + 1
        ))),
        (0, _) => Err(fail(format!(
            "an end marker on line {} with no begin marker",
            ends[0] + 1
        ))),
        (_, 0) => Err(fail(format!(
            "a begin marker on line {} with no end marker",
            begins[0] + 1
        ))),
        (b, e) => Err(fail(format!(
            "{b} begin and {e} end markers; expected exactly one of each"
        ))),
    }
}

// ── Install ──────────────────────────────────────────────────────────────────

/// Inserts or refreshes the block.
///
/// - With no block, it is appended: in `.zprofile` the last assignment wins,
///   and we need to land after things like `brew shellenv`.
/// - With a block, it is replaced **in place**, preserving its position, so a
///   user who deliberately moved it keeps their ordering.
///
/// Identical input and output means the caller should skip the write.
pub fn install(content: &str, body: &[String], markers: &Markers, path: &str) -> Result<String, Error> {
    let mut model = LineModel::parse(content);
    let mut block = Vec::with_capacity(body.len() + 2);
    block.push(markers.begin.clone());
    block.extend(body.iter().cloned());
    block.push(markers.end.clone());

    if let Some(span) = find_span(&model.lines, path)? {
        model.lines.splice(span, block);
    } else {
        let file_was_empty = model.lines.is_empty();
        // Separate from existing content with exactly one blank line, and only
        // when there is content to separate from.
        if model.lines.last().is_some_and(|l| !is_blank(l)) {
            model.lines.push(String::new());
        }
        model.lines.extend(block);
        // Only a brand-new file gets a trailing newline imposed on it. Adding
        // one to a file that lacked it would break the guarantee that
        // install-then-remove is byte-identical.
        if file_was_empty {
            model.has_trailing_newline = true;
        }
    }
    Ok(model.render())
}

// ── Remove ───────────────────────────────────────────────────────────────────

/// Deletes the block, plus the single blank separator line `install` adds. A
/// file with no block is returned untouched.
pub fn remove(content: &str, path: &str) -> Result<String, Error> {
    let mut model = LineModel::parse(content);
    let Some(span) = find_span(&model.lines, path)? else {
        return Ok(content.to_owned());
    };
    let mut lower = *span.start();
    if lower > 0 && is_blank(&model.lines[lower - 1]) {
        lower -= 1;
    }
    model.lines.drain(lower..=*span.end());
    if model.lines.is_empty() {
        model.has_trailing_newline = false;
    }
    Ok(model.render())
}

// ── Inspection ───────────────────────────────────────────────────────────────

/// The block's inner lines, excluding the markers.
pub fn extract_body(content: &str, path: &str) -> Result<Option<Vec<String>>, Error> {
    let model = LineModel::parse(content);
    let Some(span) = find_span(&model.lines, path)? else {
        return Ok(None);
    };
    let (start, end) = (*span.start(), *span.end());
    Ok(Some(model.lines[start + 1..end].to_vec()))
}

pub fn contains_block(content: &str) -> bool {
    matches!(find_span(&LineModel::parse(content).lines, "file"), Ok(Some(_)))
}
