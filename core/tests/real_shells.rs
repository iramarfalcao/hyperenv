//! O script de sessão carregado num shell de verdade tem de devolver cada
//! valor byte a byte. É a prova de que as aspas de cada dialeto estão certas —
//! um erro aqui é injeção de comando no login do usuário.
//!
//! Shell que não estiver instalado é pulado (com aviso), para a suíte rodar
//! em qualquer máquina; na CI cada sistema instala os seus.

use std::io::Write;
use std::process::{Command, Stdio};

use hyperenv_core::render::{self, Shell};
use hyperenv_core::{EnvKey, EnvSet, EnvValue};

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
    "a'b'c",
    "$(touch /tmp/hyperenv-pwned)",
    "; rm -rf ~",
    "unicode: ação ✓ 日本",
    "it’s ‘curly’",
    "\\'",
    "{braces} [brackets] *glob* ?",
];

fn vars() -> EnvSet {
    NASTY
        .iter()
        .enumerate()
        .map(|(i, v)| (EnvKey::new(format!("HV_T{i}")).unwrap(), EnvValue::from(*v)))
        .collect()
}

/// Carrega o script e imprime cada variável separada por NUL.
fn run(shell: &str, args: &[&str], script: &str, dump: &str) -> Option<Vec<u8>> {
    let mut child = Command::new(shell)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .env_remove("HYPERENV_DISABLE")
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(script.as_bytes()).unwrap();
    stdin.write_all(dump.as_bytes()).unwrap();
    drop(stdin);
    Some(child.wait_with_output().unwrap().stdout)
}

fn check(shell: Shell, exe: &str, args: &[&str], dump_one: impl Fn(&str) -> String) {
    let env = vars();
    // O `return` do guarda POSIX só vale em arquivo carregado, então o teste
    // carrega o script como função, igual ao `. arquivo` do hook.
    let script = render::session(shell, &env, "teste", "agora");
    let wrapped = match shell {
        Shell::Zsh | Shell::Bash => format!("__hv() {{\n{script}\n}}\n__hv\n"),
        _ => script,
    };
    let dump: String = env.keys().map(|k| dump_one(k.as_str())).collect();
    let Some(out) = run(exe, args, &wrapped, &dump) else {
        eprintln!("aviso: {exe} não está instalado — pulei");
        return;
    };
    let got: Vec<&[u8]> = out.split(|&b| b == 0).collect();
    for (i, (key, value)) in env.iter().enumerate() {
        assert_eq!(
            String::from_utf8_lossy(got[i]),
            value.as_str(),
            "{exe}: {key} voltou diferente"
        );
    }
    assert!(
        !std::path::Path::new("/tmp/hyperenv-pwned").exists(),
        "{exe}: valor foi executado!"
    );
}

#[test]
fn zsh_roundtrip() {
    check(Shell::Zsh, "zsh", &["-f"], |k| {
        format!("printf '%s\\0' \"${k}\"\n")
    });
}

#[test]
fn bash_roundtrip() {
    check(Shell::Bash, "bash", &["--norc", "--noprofile"], |k| {
        format!("printf '%s\\0' \"${k}\"\n")
    });
}

#[test]
fn fish_roundtrip() {
    check(Shell::Fish, "fish", &["--no-config"], |k| {
        format!("printf '%s\\0' \"${k}\"\n")
    });
}

#[test]
fn powershell_roundtrip() {
    check(Shell::PowerShell, "pwsh", &["-NoProfile", "-Command", "-"], |k| {
        format!("[Console]::Out.Write($env:{k} + [char]0)\n")
    });
}

#[test]
fn bypass_variable_disables_the_session() {
    let env: EnvSet = [(EnvKey::new("HV_BYPASS").unwrap(), EnvValue::from("set"))]
        .into_iter()
        .collect();
    let script = render::session(Shell::Zsh, &env, "t", "t");
    let out = Command::new("zsh")
        .args([
            "-f",
            "-c",
            &format!("__hv() {{\n{script}\n}}; __hv; printf '%s' \"${{HV_BYPASS-unset}}\""),
        ])
        .env("HYPERENV_DISABLE", "1")
        .output();
    let Ok(out) = out else { return };
    assert_eq!(String::from_utf8_lossy(&out.stdout), "unset");
}
