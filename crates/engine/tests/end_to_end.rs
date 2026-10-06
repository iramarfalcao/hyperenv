//! End to end in a real shell, with a throwaway home: the user already has
//! `API_URL` in their own startup file; the profile changes the value; a new
//! terminal sees the profile's; undo goes back to the original.
//!
//! A shell that is not installed is skipped with a warning.

// POSIX login shells only; Windows has no startup file to test.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use hyperenv_core::render::Shell;
use hyperenv_engine::probe::{Probe, ShellProbe};
use hyperenv_engine::{Engine, Layout, Platform, Store};

fn which(name: &str) -> Option<PathBuf> {
    let out = Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .ok()?;
    let path = String::from_utf8(out.stdout).ok()?.trim().to_owned();
    (!path.is_empty()).then(|| PathBuf::from(path))
}

/// What a new terminal sees, opening the login shell with the test home.
fn new_terminal(layout: &Layout, var: &str) -> String {
    let script = match layout.shell {
        Shell::Fish => format!("printf '%s' \"${var}\""),
        _ => format!("printf '%s' \"${{{var}-<absent>}}\""),
    };
    let mut cmd = Command::new(&layout.shell_path);
    match layout.shell {
        Shell::Fish => cmd.args(["--login", "--interactive", "--command", &script]),
        // A Linux terminal opens bash interactive but not as a login shell.
        Shell::Bash if layout.platform == Platform::Linux => cmd.args(["-i", "-c", &script]),
        _ => cmd.args(["-l", "-i", "-c", &script]),
    };
    let out = cmd
        .env_clear()
        .env("HOME", &layout.home)
        .env("TERM", "dumb")
        .env("PATH", "/usr/bin:/bin")
        .current_dir(&layout.home)
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    if layout.shell == Shell::Fish && text.is_empty() {
        "<absent>".into()
    } else {
        text
    }
}

fn scenario(shell: Shell, exe: &str, user_file: &str, user_line: &str) {
    let Some(path) = which(exe) else {
        eprintln!("warning: {exe} is not installed — skipped");
        return;
    };
    let home = tempfile::tempdir().unwrap();
    let home_path: &Path = &fs::canonicalize(home.path()).unwrap();
    let layout = Layout::in_home(home_path, Platform::current(), shell, &path);

    let user = home_path.join(user_file);
    fs::create_dir_all(user.parent().unwrap()).unwrap();
    fs::write(&user, format!("{user_line}\n")).unwrap();

    let mut store = Store::default();
    store.create("dev").unwrap();
    store
        .set_var("dev", "API_URL", "https://dev.example/#it's", None)
        .unwrap();
    store.set_var("dev", "HV_NEW", "x y", None).unwrap();
    let dev = store.get("dev").unwrap().clone();

    let probe = ShellProbe::default();
    let original = probe.observe(&layout, true).expect("shell probe");
    assert_eq!(
        original.get(&"API_URL".parse_key()).map(|v| v.as_str()),
        Some("https://prod"),
        "{exe}"
    );

    let engine = Engine::new(layout.clone(), &probe);
    engine.apply(&dev).unwrap();
    assert_eq!(
        new_terminal(&layout, "API_URL"),
        "https://dev.example/#it's",
        "{exe}: profile applied"
    );
    assert_eq!(new_terminal(&layout, "HV_NEW"), "x y", "{exe}");
    // With the bypass, the probe still sees the user's original.
    let still = probe.observe(&layout, true).unwrap();
    assert_eq!(
        still.get(&"API_URL".parse_key()).map(|v| v.as_str()),
        Some("https://prod"),
        "{exe}"
    );
    assert!(
        engine.drift().unwrap().is_empty(),
        "{exe}: no drift right after applying"
    );

    engine.unapply().unwrap();
    assert_eq!(
        new_terminal(&layout, "API_URL"),
        "https://prod",
        "{exe}: original is back"
    );
    assert_eq!(new_terminal(&layout, "HV_NEW"), "<absent>", "{exe}");
}

trait ParseKey {
    fn parse_key(&self) -> hyperenv_core::EnvKey;
}
impl ParseKey for str {
    fn parse_key(&self) -> hyperenv_core::EnvKey {
        hyperenv_core::EnvKey::new(self).unwrap()
    }
}

#[test]
fn zsh_end_to_end() {
    scenario(Shell::Zsh, "zsh", ".zprofile", "export API_URL='https://prod'");
}

#[test]
fn bash_end_to_end() {
    let file = if cfg!(target_os = "macos") {
        ".bash_profile"
    } else {
        ".bashrc"
    };
    scenario(Shell::Bash, "bash", file, "export API_URL='https://prod'");
}

#[test]
fn fish_end_to_end() {
    scenario(
        Shell::Fish,
        "fish",
        ".config/fish/config.fish",
        "set -gx API_URL 'https://prod'",
    );
}
