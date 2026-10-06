//! Quoting for each destination. Every shell has its own rules, and getting
//! one wrong is command injection into the user's login.

/// POSIX single quotes (zsh, bash, sh): the only construct that suppresses
/// *all* interpretation — `$`, backticks, `\`, `#`, `!`, spaces and newlines
/// all pass through literally.
///
/// A single quote cannot be escaped inside single quotes, so the standard
/// close/insert/reopen dance is used: `it's` becomes `'it'\''s'`. Values are
/// quoted unconditionally, even trivially safe ones: consistency is worth more
/// than prettier output.
pub fn posix_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// fish single quotes: inside them only `\'` and `\\` are escapes; everything
/// else, `$` and newlines included, is literal.
pub fn fish_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            _ => out.push(c),
        }
    }
    out.push('\'');
    out
}

/// PowerShell single quotes: literal, and a single quote is doubled (`''`).
/// PowerShell also treats the typographic quotes ‘ ’ ‚ ‛ as single quotes, so
/// those are doubled the same way.
pub fn powershell_single(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// Double-quoted form for dotenv parsers, which generally do not implement
/// POSIX single-quote semantics. Newlines become `\n` because most of those
/// parsers cannot handle a literal newline inside a value.
pub fn dotenv_double(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '$' => out.push_str("\\$"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
