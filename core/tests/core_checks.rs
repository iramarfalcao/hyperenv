//! A port of the 121 checks in `Tests/CoreChecks/main.swift`, plus the new
//! bash, fish and PowerShell cases. This is the Rust core's minimum bar.

use hyperenv_core::dotenv::{self, Dialect, Limits, Severity};
use hyperenv_core::guarded_block::{self as gb, Markers};
use hyperenv_core::reconcile::{self, DriftDetail, ManagedState};
use hyperenv_core::render::{self, Shell};
use hyperenv_core::seed::{self, Bucket};
use hyperenv_core::{EnvKey, EnvSet, EnvValue, PriorState, probe, quoting};

fn key(name: &str) -> EnvKey {
    EnvKey::new(name).unwrap()
}

fn set(pairs: &[(&str, &str)]) -> EnvSet {
    pairs.iter().map(|(k, v)| (key(k), EnvValue::from(*v))).collect()
}

fn body() -> Vec<String> {
    Shell::Zsh.hook_body("$HOME/.config/hyperenv/session.zsh")
}

fn decode(text: &str) -> dotenv::DecodeResult {
    dotenv::decode(text, Limits::default())
}

fn decode_one(text: &str) -> Option<String> {
    decode(text)
        .env_set()
        .get(&key("K"))
        .map(|v| v.as_str().to_owned())
}

// ── Managed block ────────────────────────────────────────────────────────────

const ORIGINAL: &str = "eval \"$(/opt/homebrew/bin/brew shellenv zsh)\"";

#[test]
fn install_on_empty_file() {
    let out = gb::install("", &body(), &Markers::v1(), "f").unwrap();
    assert!(!out.starts_with('\n'), "no blank line at the start");
    assert!(out.ends_with('\n'), "ends with a newline");
}

#[test]
fn install_appends_after_content_with_one_separator() {
    let m = Markers::v1();
    let out = gb::install(ORIGINAL, &body(), &m, "f").unwrap();
    assert!(out.starts_with(ORIGINAL));
    assert!(out.contains(&format!("{ORIGINAL}\n\n{}", m.begin)));
}

#[test]
fn install_is_idempotent() {
    let m = Markers::v1();
    let once = gb::install(ORIGINAL, &body(), &m, "f").unwrap();
    let twice = gb::install(&once, &body(), &m, "f").unwrap();
    assert_eq!(twice, once);
}

#[test]
fn remove_restores_original_bytes() {
    let m = Markers::v1();
    let installed = gb::install(ORIGINAL, &body(), &m, "f").unwrap();
    assert_eq!(gb::remove(&installed, "f").unwrap(), ORIGINAL);

    let with_nl = format!("{ORIGINAL}\n");
    let roundtrip = gb::remove(&gb::install(&with_nl, &body(), &m, "f").unwrap(), "f").unwrap();
    assert_eq!(roundtrip, with_nl);
}

#[test]
fn crlf_survives() {
    let m = Markers::v1();
    let crlf = "line one\r\nline two\r\n";
    let installed = gb::install(crlf, &body(), &m, "f").unwrap();
    assert!(installed.contains("\r\n") && !installed.contains("\n\n"));
    assert_eq!(gb::remove(&installed, "f").unwrap(), crlf);
}

#[test]
fn block_in_the_middle_is_replaced_in_place() {
    let m = Markers::v1();
    let middle = format!("before\n\n{}\nOLD\n{}\n\nafter\n", m.begin, m.end);
    let out = gb::install(&middle, &["NEW".to_owned()], &m, "f").unwrap();
    assert_eq!(out, format!("before\n\n{}\nNEW\n{}\n\nafter\n", m.begin, m.end));
}

#[test]
fn marker_inside_a_comment_is_ignored() {
    assert!(!gb::contains_block(
        "# do not touch the # >>> hyperenv managed block thing\n"
    ));
}

#[test]
fn malformed_markers_refuse_instead_of_guessing() {
    let m = Markers::v1();
    let (b, e) = (&m.begin, &m.end);
    for bad in [
        format!("{b}\nx\n"),
        format!("{e}\n"),
        format!("{b}\n{e}\n{b}\n{e}\n"),
        format!("{e}\n{b}\n"),
    ] {
        assert!(
            gb::install(&bad, &body(), &m, "f").is_err(),
            "should refuse: {bad:?}"
        );
    }
}

#[test]
fn remove_without_block_is_noop() {
    assert_eq!(gb::remove(ORIGINAL, "f").unwrap(), ORIGINAL);
}

#[test]
fn extract_body_returns_inner_lines() {
    let m = Markers::v1();
    let installed = gb::install("", &["a".into(), "b".into()], &m, "f").unwrap();
    assert_eq!(
        gb::extract_body(&installed, "f").unwrap(),
        Some(vec!["a".into(), "b".into()])
    );
    assert_eq!(gb::extract_body("nada", "f").unwrap(), None);
}

// ── Quoting and round trips through .env ─────────────────────────────────────

const NASTY: &[&str] = &[
    "simple",
    "with spaces",
    "it's",
    "quote\" and 'single'",
    "dollar $HOME and `backtick`",
    "hash # not a comment",
    "back\\slash",
    "multi\nline\nvalue",
    "",
    "trailing space ",
    "#leading hash",
    "a'b'c",
    "$(rm -rf /)",
];

#[test]
fn roundtrip_posix_dialect() {
    for raw in NASTY {
        let (text, diags) = dotenv::encode(&set(&[("V", raw)]), Dialect::PosixShell, &[], false);
        let back = decode(&text);
        assert!(!back.has_errors() && diags.is_empty(), "{raw:?}");
        assert_eq!(
            back.env_set().get(&key("V")).map(|v| v.as_str()),
            Some(*raw),
            "{raw:?}"
        );
    }
}

#[test]
fn roundtrip_dotenv_dialect() {
    for raw in NASTY {
        let (text, _) = dotenv::encode(&set(&[("V", raw)]), Dialect::Dotenv, &[], false);
        assert_eq!(
            decode(&text).env_set().get(&key("V")).map(|v| v.as_str()),
            Some(*raw),
            "{raw:?}"
        );
    }
}

// ── .env parsing details ─────────────────────────────────────────────────────

#[test]
fn dotenv_parsing_specifics() {
    assert_eq!(decode_one("K='it'\\''s'").as_deref(), Some("it's"));
    assert_eq!(decode_one("K='a'\"b\"").as_deref(), Some("ab"));
    assert_eq!(decode_one("K=value # trailing").as_deref(), Some("value"));
    assert_eq!(decode_one("K=abc#def").as_deref(), Some("abc#def"));
    assert_eq!(decode_one("export K=v").as_deref(), Some("v"));
    assert_eq!(decode_one("K=\"a\\nb\"").as_deref(), Some("a\nb"));
    assert_eq!(decode_one("K='a\\nb'").as_deref(), Some("a\\nb"));
    assert_eq!(decode_one("K=").as_deref(), Some(""));
    assert_eq!(decode_one("K='line1\nline2'").as_deref(), Some("line1\nline2"));
}

#[test]
fn dotenv_space_around_equals_warns_but_parses() {
    let r = decode("K = v");
    assert!(r.diagnostics.iter().any(|d| d.severity == Severity::Warning));
    assert_eq!(r.env_set().get(&key("K")).map(|v| v.as_str()), Some("v"));
}

#[test]
fn dotenv_invalid_key_is_rejected_per_row() {
    let r = decode("9BAD=x\nGOOD=y");
    assert_eq!(r.entries.len(), 1);
    assert_eq!(r.env_set().get(&key("GOOD")).map(|v| v.as_str()), Some("y"));
    assert!(r.has_errors());
}

#[test]
fn dotenv_duplicates_last_wins_and_warn() {
    let r = decode("K=first\nK=second");
    assert_eq!(r.env_set().get(&key("K")).map(|v| v.as_str()), Some("second"));
    assert!(r.diagnostics.iter().any(|d| d.severity == Severity::Warning));
}

#[test]
fn dotenv_misc() {
    assert!(decode("K='oops").has_errors());
    assert_eq!(decode("# header\n\n  # indented\nK=v\n").entries.len(), 1);
    let crlf = decode("A=1\r\nB=2\r\n");
    assert_eq!(crlf.entries.len(), 2);
    assert_eq!(crlf.env_set().get(&key("B")).map(|v| v.as_str()), Some("2"));
    assert_eq!(decode_one("\u{FEFF}K=v").as_deref(), Some("v"));
    let no_eq = decode("JUST_A_WORD\nK=v");
    assert!(no_eq.entries.len() == 1 && no_eq.has_errors());
}

#[test]
fn dotenv_unterminated_quote_skips_the_line() {
    let r = decode("K='oops\nOTHER=1");
    assert!(r.has_errors());
    assert!(r.env_set().get(&key("K")).is_none());
}

#[test]
fn docker_dialect_refuses_newlines() {
    let (_, diags) = dotenv::encode(&set(&[("K", "a\nb")]), Dialect::Docker, &[], false);
    assert!(diags.iter().any(|d| d.severity == Severity::Error));
}

#[test]
fn encode_is_sorted() {
    let (text, _) = dotenv::encode(
        &set(&[("ZED", "x"), ("ALPHA", "x"), ("MIKE", "x")]),
        Dialect::PosixShell,
        &[],
        false,
    );
    let pos = |s: &str| text.find(s).unwrap();
    assert!(pos("ALPHA") < pos("MIKE") && pos("MIKE") < pos("ZED"));
}

// ── Names ────────────────────────────────────────────────────────────────────

#[test]
fn key_validation() {
    for bad in ["1ABC", "A-B", "", "A B", "ÁGUA"] {
        assert!(EnvKey::new(bad).is_none(), "{bad:?}");
    }
    assert!(EnvKey::new("_A1").is_some());
}

// ── Prior state: empty must not become absent ────────────────────────────────

#[test]
fn prior_state_roundtrips_and_keeps_empty_distinct() {
    for state in [
        PriorState::Absent,
        PriorState::Present("".into()),
        PriorState::Present("x".into()),
    ] {
        let json = serde_json::to_string(&state).unwrap();
        let back: PriorState = serde_json::from_str(&json).unwrap();
        assert_eq!(back, state);
    }
    assert_ne!(PriorState::Present("".into()), PriorState::Absent);
}

#[test]
fn prior_state_json_matches_the_swift_journal() {
    assert_eq!(
        serde_json::to_string(&PriorState::Absent).unwrap(),
        r#"{"state":"absent"}"#
    );
    assert_eq!(
        serde_json::to_string(&PriorState::Present("v".into())).unwrap(),
        r#"{"state":"present","value":"v"}"#
    );
}

// ── Generated scripts ────────────────────────────────────────────────────────

fn session_vars() -> EnvSet {
    set(&[("API_URL", "https://x.test/#frag"), ("TOKEN", "it's secret")])
}

#[test]
fn zsh_session_has_bypass_before_exports_and_quotes() {
    let s = render::session(Shell::Zsh, &session_vars(), "dev", "now");
    assert!(s.find("HYPERENV_DISABLE").unwrap() < s.find("export API_URL").unwrap());
    assert!(s.contains("export TOKEN='it'\\''s secret'"));
}

#[test]
fn bash_session_is_posix() {
    let s = render::session(Shell::Bash, &session_vars(), "dev", "now");
    assert!(s.contains("export TOKEN='it'\\''s secret'"));
    assert!(s.contains("[[ -n \"$HYPERENV_DISABLE\" ]] && return"));
}

#[test]
fn fish_session_wraps_in_guard_and_quotes() {
    let s = render::session(Shell::Fish, &session_vars(), "dev", "now");
    assert!(s.contains("if test -z \"$HYPERENV_DISABLE\""));
    assert!(s.contains("    set -gx TOKEN 'it\\'s secret'"));
    assert!(s.trim_end().ends_with("end"));
}

#[test]
fn powershell_session_doubles_single_quotes() {
    let s = render::session(Shell::PowerShell, &session_vars(), "dev", "now");
    assert!(s.contains("$env:TOKEN = 'it''s secret'"));
    assert!(s.trim_end().ends_with('}'));
}

#[test]
fn inverse_scripts_unset_and_restore() {
    let entries = vec![
        (key("A"), PriorState::Absent),
        (key("B"), PriorState::Present("old".into())),
    ];
    let zsh = render::inverse(Shell::Zsh, &entries, "now", "~/u.zsh");
    assert!(zsh.contains("unset A") && zsh.contains("export B='old'"));
    let fish = render::inverse(Shell::Fish, &entries, "now", "~/u.fish");
    assert!(fish.contains("set -e A") && fish.contains("set -gx B 'old'"));
    let ps = render::inverse(Shell::PowerShell, &entries, "now", "u.ps1");
    assert!(ps.contains("Remove-Item Env:A") && ps.contains("$env:B = 'old'"));
}

#[test]
fn quoting_edge_cases() {
    assert_eq!(quoting::fish_single("a\\b'c"), "'a\\\\b\\'c'");
    assert_eq!(quoting::powershell_single("it’s"), "'it’’s'");
    assert_eq!(quoting::posix_single(""), "''");
}

#[test]
fn shell_detection() {
    assert_eq!(Shell::from_path("/bin/zsh"), Some(Shell::Zsh));
    assert_eq!(Shell::from_path("/usr/local/bin/fish"), Some(Shell::Fish));
    assert_eq!(
        Shell::from_path("C:\\Program Files\\PowerShell\\7\\pwsh.exe"),
        Some(Shell::PowerShell)
    );
    assert_eq!(Shell::from_path("/bin/tcsh"), None);
}

// ── Reconciliation: the capture-once invariant ───────────────────────────────

#[test]
fn capture_once_invariant() {
    let user_env = set(&[("API_URL", "https://prod.example"), ("KEEP", "untouched")]);
    let plan_a = reconcile::plan(
        &set(&[("API_URL", "https://dev.example"), ("NEW_VAR", "1")]),
        &ManagedState::new(),
        &user_env,
    );
    assert_eq!(
        plan_a.captures.get(&key("API_URL")),
        Some(&PriorState::Present("https://prod.example".into()))
    );
    assert_eq!(plan_a.captures.get(&key("NEW_VAR")), Some(&PriorState::Absent));
    assert!(!plan_a.captures.contains_key(&key("KEEP")));

    // The environment the probe would see has already been changed by A —
    // re-capturing here is the classic bug.
    let polluted = set(&[
        ("API_URL", "https://dev.example"),
        ("KEEP", "untouched"),
        ("NEW_VAR", "1"),
    ]);
    let plan_b = reconcile::plan(
        &set(&[("API_URL", "https://hml.example"), ("NEW_VAR", "2")]),
        &plan_a.resulting_state,
        &polluted,
    );
    assert!(plan_b.captures.is_empty());
    assert_eq!(
        plan_b.resulting_state.baseline(&key("API_URL")),
        Some(&PriorState::Present("https://prod.example".into()))
    );

    let undo = reconcile::unapply_plan(&plan_b.resulting_state);
    assert_eq!(
        undo.restores.get(&key("API_URL")),
        Some(&PriorState::Present("https://prod.example".into()))
    );
    assert_eq!(undo.restores.get(&key("NEW_VAR")), Some(&PriorState::Absent));
    assert!(undo.resulting_state.is_empty());

    let plan_c = reconcile::plan(
        &set(&[("API_URL", "https://hml.example")]),
        &plan_b.resulting_state,
        &polluted,
    );
    assert_eq!(plan_c.restores.get(&key("NEW_VAR")), Some(&PriorState::Absent));
    assert!(!plan_c.resulting_state.is_managed(&key("NEW_VAR")));
    assert!(plan_c.resulting_state.is_managed(&key("API_URL")));
}

#[test]
fn empty_string_is_a_real_baseline() {
    let p = reconcile::plan(&set(&[("E", "x")]), &ManagedState::new(), &set(&[("E", "")]));
    assert_eq!(p.captures.get(&key("E")), Some(&PriorState::Present("".into())));
}

#[test]
fn inverse_entries_merge_captures_and_restores() {
    let a = reconcile::plan(
        &set(&[("A", "1"), ("B", "2")]),
        &ManagedState::new(),
        &set(&[("B", "old")]),
    );
    let b = reconcile::plan(
        &set(&[("A", "1"), ("C", "3")]),
        &a.resulting_state,
        &EnvSet::new(),
    );
    let keys: Vec<String> = b
        .inverse_entries()
        .into_iter()
        .map(|(k, _)| k.to_string())
        .collect();
    assert_eq!(keys, ["B", "C"]);
}

#[test]
fn semantic_drift_detection() {
    let d = reconcile::semantic_drift(
        &set(&[("A", "1"), ("B", "2"), ("C", "3")]),
        &set(&[("A", "1"), ("B", "shadowed")]),
    );
    assert!(!d.contains_key(&key("A")));
    assert_eq!(
        d.get(&key("B")),
        Some(&DriftDetail::Shadowed {
            expected: "2".into(),
            actual: "shadowed".into()
        })
    );
    assert_eq!(
        d.get(&key("C")),
        Some(&DriftDetail::Missing { expected: "3".into() })
    );
}

// ── Probe ────────────────────────────────────────────────────────────────────

#[test]
fn probe_parses_after_sentinel_and_keeps_newlines() {
    let mut data = b"prompt banner\njunk=1\0".to_vec();
    data.extend_from_slice(probe::SENTINEL.as_bytes());
    data.extend_from_slice(b"\nA=1\0MULTI=x\ny\0bad-name=z\0\0");
    let env = probe::parse_nul_separated(&data).unwrap();
    assert_eq!(env.get(&key("A")).map(|v| v.as_str()), Some("1"));
    assert_eq!(env.get(&key("MULTI")).map(|v| v.as_str()), Some("x\ny"));
    assert!(env.get(&key("junk")).is_none());
    assert_eq!(env.len(), 2);
    assert!(probe::parse_nul_separated(b"no marker").is_err());
}

// ── Classifying the existing environment ─────────────────────────────────────

#[test]
fn seed_classification() {
    let c = |k: &str, v: &str| seed::classify(&key(k), &v.into());
    assert_eq!(c("PATH", "/usr/bin"), Bucket::PathLike);
    assert_eq!(c("GOPATH", "/a:/b"), Bucket::PathLike);
    assert_eq!(c("TMPDIR", "/var/folders/x"), Bucket::Session);
    assert_eq!(c("SSH_AUTH_SOCK", "/var/run/x"), Bucket::Session);
    assert_eq!(c("HOMEBREW_PREFIX", "/opt/homebrew"), Bucket::Derived);
    assert_eq!(c("DYLD_LIBRARY_PATH", "/x"), Bucket::Rejected);
    assert_eq!(c("__CFBundleIdentifier", "x"), Bucket::Cosmetic);
    assert_eq!(c("HOME", "/Users/x"), Bucket::Session);
    assert_eq!(c("MY_API_TOKEN", "abc"), Bucket::User);
    // Linux and Windows
    assert_eq!(c("XDG_RUNTIME_DIR", "/run/user/1000"), Bucket::Session);
    assert_eq!(c("LD_PRELOAD", "/x.so"), Bucket::Rejected);
    assert_eq!(c("USERPROFILE", "C:\\Users\\x"), Bucket::Session);
    assert_eq!(c("PSModulePath", "C:\\a;C:\\b"), Bucket::PathLike);
}

#[test]
fn seed_base_subtraction() {
    let classified = seed::classify_observed(
        &set(&[
            ("HOME", "/Users/x"),
            ("LANG", "en_US.UTF-8"),
            ("MY_VAR", "v"),
            ("TERM", "xterm"),
        ]),
        &set(&[("HOME", "/Users/x"), ("LANG", "C")]),
    );
    let imp = classified.importable();
    assert!(!imp.contains(&key("HOME")));
    assert!(imp.contains(&key("LANG")));
    assert!(imp.contains(&key("MY_VAR")));
    assert!(!imp.contains(&key("TERM")));
    assert!(classified.set(Bucket::Cosmetic).contains(&key("TERM")));
}
