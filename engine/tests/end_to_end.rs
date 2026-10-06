//! Ponta a ponta num shell de verdade, com uma home descartável: o usuário
//! já tem `API_URL` no próprio arquivo de inicialização; o perfil troca o
//! valor; um terminal novo vê o do perfil; desfazer volta ao original.
//!
//! Shell não instalado é pulado com aviso.

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

/// O que um terminal novo enxerga, abrindo o shell de login com a home de teste.
fn new_terminal(layout: &Layout, var: &str) -> String {
    let script = match layout.shell {
        Shell::Fish => format!("printf '%s' \"${var}\""),
        _ => format!("printf '%s' \"${{{var}-<ausente>}}\""),
    };
    let mut cmd = Command::new(&layout.shell_path);
    match layout.shell {
        Shell::Fish => cmd.args(["--login", "--interactive", "--command", &script]),
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
        "<ausente>".into()
    } else {
        text
    }
}

fn scenario(shell: Shell, exe: &str, user_file: &str, user_line: &str) {
    let Some(path) = which(exe) else {
        eprintln!("aviso: {exe} não está instalado — pulei");
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
    store.set_var("dev", "HV_NOVA", "x y", None).unwrap();
    let dev = store.get("dev").unwrap().clone();

    let probe = ShellProbe::default();
    let original = probe.observe(&layout, true).expect("sondagem do shell");
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
        "{exe}: perfil aplicado"
    );
    assert_eq!(new_terminal(&layout, "HV_NOVA"), "x y", "{exe}");
    // Com o bypass a sondagem continua vendo o original do usuário.
    let still = probe.observe(&layout, true).unwrap();
    assert_eq!(
        still.get(&"API_URL".parse_key()).map(|v| v.as_str()),
        Some("https://prod"),
        "{exe}"
    );
    assert!(
        engine.drift().unwrap().is_empty(),
        "{exe}: sem divergência logo após aplicar"
    );

    engine.unapply().unwrap();
    assert_eq!(
        new_terminal(&layout, "API_URL"),
        "https://prod",
        "{exe}: original de volta"
    );
    assert_eq!(new_terminal(&layout, "HV_NOVA"), "<ausente>", "{exe}");
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
