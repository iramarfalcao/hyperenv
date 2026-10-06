//! Os scripts gerados, em cada dialeto de shell.
//!
//! Dois por aplicação: o de sessão (o que os terminais novos carregam) e o
//! inverso (para desfazer num terminal que já estava aberto).

use crate::quoting::{fish_single, posix_single, powershell_single};
use crate::types::{EnvKey, EnvSet, PriorState};

/// Com isto no ambiente, o script de sessão não faz nada.
///
/// É a linha que torna o resto possível: capturar o estado original, detectar
/// divergência e ressincronizar precisam ver o shell *como se o HyperEnv não
/// estivesse instalado*, sem mover nem renomear arquivos do usuário.
pub const BYPASS_VARIABLE: &str = "HYPERENV_DISABLE";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Shell {
    Zsh,
    Bash,
    Fish,
    /// Windows: o ambiente persistente vai pelo registro; o script serve para
    /// aplicar ou desfazer num PowerShell que já estava aberto.
    PowerShell,
}

impl Shell {
    /// Extensão do script gerado (`session.zsh`, `unsession.fish`…).
    pub fn extension(self) -> &'static str {
        match self {
            Shell::Zsh => "zsh",
            Shell::Bash => "bash",
            Shell::Fish => "fish",
            Shell::PowerShell => "ps1",
        }
    }

    /// Reconhece o shell pelo caminho do executável (`/bin/zsh`, `fish`…).
    pub fn from_path(path: &str) -> Option<Shell> {
        let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
        let name = name.strip_suffix(".exe").unwrap_or(name);
        match name {
            "zsh" => Some(Shell::Zsh),
            "bash" => Some(Shell::Bash),
            "fish" => Some(Shell::Fish),
            "pwsh" | "powershell" => Some(Shell::PowerShell),
            _ => None,
        }
    }

    fn comment(self) -> &'static str {
        "#"
    }

    fn export_line(self, key: &EnvKey, value: &str) -> String {
        match self {
            Shell::Zsh | Shell::Bash => format!("export {key}={}", posix_single(value)),
            Shell::Fish => format!("set -gx {key} {}", fish_single(value)),
            Shell::PowerShell => format!("$env:{key} = {}", powershell_single(value)),
        }
    }

    fn unset_line(self, key: &EnvKey) -> String {
        match self {
            Shell::Zsh | Shell::Bash => format!("unset {key}"),
            Shell::Fish => format!("set -e {key}"),
            Shell::PowerShell => format!("Remove-Item Env:{key} -ErrorAction SilentlyContinue"),
        }
    }

    /// Abre o trecho que só roda sem o bypass. POSIX usa `return` cedo; fish e
    /// PowerShell envolvem as linhas num `if`, porque `return` fora de função
    /// não é confiável neles.
    fn guard_open(self) -> &'static str {
        match self {
            Shell::Zsh | Shell::Bash => "[[ -n \"$HYPERENV_DISABLE\" ]] && return",
            Shell::Fish => "if test -z \"$HYPERENV_DISABLE\"",
            Shell::PowerShell => "if (-not $env:HYPERENV_DISABLE) {",
        }
    }

    fn guard_close(self) -> Option<&'static str> {
        match self {
            Shell::Zsh | Shell::Bash => None,
            Shell::Fish => Some("end"),
            Shell::PowerShell => Some("}"),
        }
    }

    fn indent(self) -> &'static str {
        match self {
            Shell::Zsh | Shell::Bash => "",
            Shell::Fish | Shell::PowerShell => "    ",
        }
    }

    /// A linha que o arquivo de inicialização do usuário (ou o `conf.d` do
    /// fish) usa para carregar o script de sessão.
    pub fn hook_body(self, session_path: &str) -> Vec<String> {
        match self {
            Shell::Zsh | Shell::Bash => {
                vec![format!("[ -r \"{session_path}\" ] && . \"{session_path}\"")]
            }
            Shell::Fish => vec![format!(
                "test -r \"{session_path}\"; and source \"{session_path}\""
            )],
            Shell::PowerShell => {
                vec![format!(
                    "if (Test-Path \"{session_path}\") {{ . \"{session_path}\" }}"
                )]
            }
        }
    }
}

fn header(shell: Shell, notes: &[String]) -> Vec<String> {
    let c = shell.comment();
    let mut lines = vec![format!(
        "{c} Gerado pelo HyperEnv. Não edite — é sobrescrito a cada aplicação."
    )];
    lines.extend(notes.iter().map(|n| format!("{c} {n}")));
    lines
}

fn finish(lines: Vec<String>) -> String {
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// O script de sessão.
///
/// Só tem exports. Uma variável que o perfil anterior definia e este não
/// define simplesmente não aparece: um shell *novo* nunca a teve, então o
/// valor do próprio usuário (definido antes nos dotfiles dele) fica intacto.
pub fn session(shell: Shell, variables: &EnvSet, profile: &str, applied_at: &str) -> String {
    let mut lines = header(
        shell,
        &[format!("Perfil: {profile}"), format!("Aplicado: {applied_at}")],
    );
    lines.push(String::new());
    lines.push(shell.guard_open().to_owned());
    if shell.guard_close().is_none() {
        lines.push(String::new());
    }
    for (key, value) in variables.iter() {
        lines.push(format!(
            "{}{}",
            shell.indent(),
            shell.export_line(key, value.as_str())
        ));
    }
    if let Some(close) = shell.guard_close() {
        lines.push(close.to_owned());
    }
    finish(lines)
}

/// O script inverso, para terminais que *já estão abertos* e já carregaram uma
/// sessão. Carregar um script não desfaz export nenhum, então o desfazer tem
/// de ser escrito explicitamente.
///
/// Gerado na hora de aplicar, não na de desfazer: continua valendo mesmo se o
/// HyperEnv for apagado antes de o usuário reverter.
pub fn inverse(shell: Shell, entries: &[(EnvKey, PriorState)], applied_at: &str, path: &str) -> String {
    let mut lines = header(
        shell,
        &[
            format!("Desfaz o ambiente aplicado em {applied_at}."),
            format!("Rode: {}", source_command(shell, path)),
        ],
    );
    lines.push(String::new());
    let mut sorted: Vec<&(EnvKey, PriorState)> = entries.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    for (key, prior) in sorted {
        lines.push(match prior {
            PriorState::Absent => shell.unset_line(key),
            PriorState::Present(v) => shell.export_line(key, v.as_str()),
        });
    }
    finish(lines)
}

/// Como o usuário carrega um script no shell atual.
pub fn source_command(shell: Shell, path: &str) -> String {
    match shell {
        Shell::Zsh | Shell::Bash | Shell::Fish => format!("source {path}"),
        Shell::PowerShell => format!(". \"{path}\""),
    }
}
