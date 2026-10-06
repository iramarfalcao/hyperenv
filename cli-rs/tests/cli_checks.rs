//! The whole `hyperenv` grammar against a throwaway home (`--home`), including
//! a real apply and undo in zsh — the real home is never touched. This is the
//! contract the plugins read.

use std::path::Path;
use std::process::Command;

use serde_json::Value;

fn hv(home: &Path, args: &[&str]) -> (i32, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_hyperenv"))
        .args(["--home", home.to_str().unwrap(), "--shell", "/bin/zsh"])
        .args(args)
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// `--json`: returns `data` and checks the envelope.
fn ok(home: &Path, args: &[&str]) -> Value {
    let mut full = vec!["--json"];
    full.extend_from_slice(args);
    let (code, out, err) = hv(home, &full);
    let v: Value = serde_json::from_str(&out).unwrap_or_else(|_| panic!("invalid JSON: {out} {err}"));
    assert_eq!(v["ok"], true, "{args:?}: {v}");
    assert_eq!(code, 0);
    v["data"].clone()
}

fn fails(home: &Path, args: &[&str]) -> String {
    let mut full = vec!["--json"];
    full.extend_from_slice(args);
    let (code, out, _) = hv(home, &full);
    let v: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["ok"], false, "{args:?} should have failed: {v}");
    assert_eq!(code, 1);
    v["error"].as_str().unwrap().to_owned()
}

#[test]
fn profile_and_variable_grammar() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    assert_eq!(ok(h, &["profiles"]), serde_json::json!([]));
    ok(h, &["profile", "create", "api-local"]);
    assert!(fails(h, &["profile", "create", "API-LOCAL"]).contains("already exists"));
    ok(
        h,
        &["var", "set", "api-local", "DATABASE_URL=postgres://u:p@h/db?a=b"],
    );
    ok(h, &["var", "set", "api-local", "PORT=8080", "--no-secret"]);
    ok(h, &["var", "set", "api-local", "PORT=9090"]);
    assert!(
        fails(h, &["var", "set", "api-local", "9X=1"]).contains("is not a valid environment variable name")
    );
    ok(h, &["profile", "duplicate", "api-local", "api-prod"]);
    ok(h, &["var", "disable", "api-prod", "PORT"]);
    ok(h, &["profile", "rename", "api-prod", "api-production"]);

    let vars = ok(h, &["vars", "api-local"]);
    assert_eq!(vars[0]["key"], "DATABASE_URL");
    assert_eq!(
        vars[0]["value"], "postgres://u:p@h/db?a=b",
        "the first = splits; the rest is the value"
    );
    assert_eq!(vars[0]["isSecret"], true);
    assert_eq!(vars[1]["value"], "9090");

    let list = ok(h, &["profiles"]);
    assert_eq!(list.as_array().unwrap().len(), 2);
    assert_eq!(list[1]["name"], "api-production");
    assert_eq!(list[1]["enabledCount"], 1);

    // Text: the secret is masked without --show.
    let (_, text, _) = hv(h, &["vars", "api-local"]);
    assert!(text.contains("••••") && !text.contains("postgres://"));
    let (_, shown, _) = hv(h, &["vars", "api-local", "--show"]);
    assert!(shown.contains("postgres://"));

    ok(h, &["var", "delete", "api-local", "PORT"]);
    assert!(fails(h, &["var", "delete", "api-local", "PORT"]).contains("has no"));
    ok(h, &["profile", "delete", "api-production"]);
    assert!(fails(h, &["vars", "nothing"]).contains("No profile named"));
}

#[test]
fn import_and_export() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    let env = h.join("app.env");
    std::fs::write(&env, "A=1\nexport B='it'\\''s'\n9BAD=x\nSTRIPE_SECRET_KEY=sk\n").unwrap();
    ok(h, &["profile", "create", "p"]);
    let r = ok(h, &["import", "p", env.to_str().unwrap()]);
    assert_eq!(r["imported"], 3);
    assert_eq!(r["diagnostics"][0]["severity"], "error");

    let posix = ok(h, &["export", "p", "--dialect", "posix"]);
    assert!(posix["text"].as_str().unwrap().contains("B='it'\\''s'"));
    let docker = ok(h, &["export", "p", "--dialect", "docker"]);
    assert!(docker["text"].as_str().unwrap().contains("B=it's"));
}

// On Windows the command applies to the real HKCU — not something a test should do.
#[cfg(unix)]
#[test]
fn apply_status_drift_unapply_in_real_zsh() {
    let home = tempfile::tempdir().unwrap();
    let h = &std::fs::canonicalize(home.path()).unwrap();
    std::fs::write(h.join(".zprofile"), "export API_URL='https://prod'\n").unwrap();
    ok(h, &["profile", "create", "dev"]);
    ok(h, &["var", "set", "dev", "API_URL=https://dev"]);

    let before = ok(h, &["status"]);
    assert!(before.get("applied").is_none(), "no key when nothing is applied");
    assert_eq!(before["hook"], "notInstalled");

    let plan = ok(h, &["plan", "dev"]);
    assert_eq!(plan["captured"], serde_json::json!(["API_URL"]));

    let applied = ok(h, &["apply", "dev"]);
    assert_eq!(applied["applied"], "dev");
    assert_eq!(applied["reloadCommand"], "source ~/.config/hyperenv/session.zsh");

    let st = ok(h, &["status"]);
    assert_eq!(st["applied"]["profileName"], "dev");
    assert_eq!(st["hook"], "installed");
    assert_eq!(st["drift"], serde_json::json!([]));
    assert!(fails(h, &["profile", "delete", "dev"]).contains("is applied"));
    assert_eq!(ok(h, &["profiles"])[0]["isApplied"], true);

    let undone = ok(h, &["unapply"]);
    assert_eq!(
        undone["restored"][0],
        serde_json::json!({ "key": "API_URL", "to": "https://prod" })
    );
    assert!(ok(h, &["status"]).get("applied").is_none());
    assert_eq!(
        ok(h, &["unapply"])["restored"],
        serde_json::json!([]),
        "undoing again does nothing"
    );

    ok(h, &["hook", "remove"]);
    assert_eq!(
        std::fs::read_to_string(h.join(".zprofile")).unwrap(),
        "export API_URL='https://prod'\n"
    );
}

#[test]
fn usage_errors_exit_2_and_json_errors_exit_1() {
    let home = tempfile::tempdir().unwrap();
    let (code, _, err) = hv(home.path(), &["fly"]);
    assert_eq!(code, 2);
    assert!(err.contains("unrecognized command") && err.contains("usage:"));
    assert!(fails(home.path(), &["var", "set", "p", "NO_EQUALS"]).contains("KEY=VALUE"));
    assert_eq!(
        ok(home.path(), &["version"])["version"],
        env!("CARGO_PKG_VERSION")
    );
}
