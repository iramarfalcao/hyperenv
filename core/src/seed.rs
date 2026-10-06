//! Decide quais variáveis já existentes na máquina entram no perfil padrão.
//!
//! Tudo é separado em grupos, nada é jogado fora: a comparação de divergência
//! depois precisa saber que uma variável foi *vista e excluída de propósito*,
//! e não que simplesmente não existia.

use std::collections::BTreeMap;

use crate::types::{EnvKey, EnvSet, EnvValue};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Bucket {
    /// Configuração real do usuário. É o que o perfil padrão mostra.
    User,
    /// Produzida por ferramenta, não escrita pelo usuário (`brew shellenv`…).
    Derived,
    /// Vale agora e não depois. Reaplicar aponta para caminhos mortos.
    Session,
    /// Listas de busca separadas por `:`/`;`. Nunca fotografadas inteiras.
    PathLike,
    /// Contabilidade de prompt e terminal.
    Cosmetic,
    /// Recusadas de vez — regravar quebraria coisas.
    Rejected,
}

impl Bucket {
    pub fn is_importable(self) -> bool {
        self == Bucket::User
    }
}

/// Recriadas com outro nome a cada login: nunca reaplicar.
const SESSION_SCOPED: &[&str] = &[
    // macOS
    "TMPDIR",
    "SECURITYSESSIONID",
    "Apple_PubSub_Socket_Render",
    "XPC_FLAGS",
    "XPC_SERVICE_NAME",
    "COMMAND_MODE",
    "MallocNanoZone",
    "OSLogRateLimit",
    "NoDefaultCurrentDirectoryInExePath",
    // SSH
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "SSH_CLIENT",
    "SSH_CONNECTION",
    "SSH_TTY",
    // Linux (sessão gráfica e systemd)
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_ID",
    "XDG_SESSION_TYPE",
    "XDG_SESSION_CLASS",
    "XDG_SEAT",
    "XDG_VTNR",
    "DBUS_SESSION_BUS_ADDRESS",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "INVOCATION_ID",
    "JOURNAL_STREAM",
    "MANAGERPID",
    "SYSTEMD_EXEC_PID",
    // Windows
    "SESSIONNAME",
    "CLIENTNAME",
    "LOGONSERVER",
    "TEMP",
    "TMP",
];

/// A identidade da própria conta — nunca é do HyperEnv gerenciar.
const IDENTITY: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "PWD",
    "OLDPWD",
    "USERNAME",
    // Windows
    "USERPROFILE",
    "USERDOMAIN",
    "USERDOMAIN_ROAMINGPROFILE",
    "COMPUTERNAME",
    "HOMEDRIVE",
    "HOMEPATH",
    "APPDATA",
    "LOCALAPPDATA",
    "SystemRoot",
    "SystemDrive",
    "windir",
    "ComSpec",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "ProgramW6432",
    "PUBLIC",
    "ALLUSERSPROFILE",
    "OS",
    "PROCESSOR_ARCHITECTURE",
    "NUMBER_OF_PROCESSORS",
];

const PATH_LIKE: &[&str] = &[
    "PATH",
    "FPATH",
    "MANPATH",
    "INFOPATH",
    "PKG_CONFIG_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "CPATH",
    "LIBRARY_PATH",
    "LD_LIBRARY_PATH",
    "XDG_DATA_DIRS",
    "XDG_CONFIG_DIRS",
    "PATHEXT",
    "PSModulePath",
];

const COSMETIC: &[&str] = &[
    "_",
    "SHLVL",
    "PS1",
    "PS2",
    "PROMPT",
    "RPROMPT",
    "TERM",
    "COLORTERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERM_SESSION_ID",
    "ITERM_SESSION_ID",
    "ITERM_PROFILE",
    "WINDOWID",
    "COLUMNS",
    "LINES",
    "LC_TERMINAL",
    "LC_TERMINAL_VERSION",
    "EDITOR_TERM",
    "WT_SESSION",
    "WT_PROFILE_ID",
    "VTE_VERSION",
    "KONSOLE_VERSION",
];

const COSMETIC_PREFIXES: &[&str] = &["__CF", "__", "LC_TERMINAL"];
const DERIVED_PREFIXES: &[&str] = &["HOMEBREW_"];

/// `DYLD_*` é removido pelo SIP em processos protegidos e definir pode quebrar
/// binários assinados; `LD_PRELOAD` injeta código em todo processo. Aparecem,
/// mas nunca são gravados.
const REJECTED_PREFIXES: &[&str] = &["DYLD_", "LD_PRELOAD", "LD_AUDIT"];

pub fn classify(key: &EnvKey, value: &EnvValue) -> Bucket {
    let name = key.as_str();
    let starts = |list: &[&str]| list.iter().any(|p| name.starts_with(p));

    if starts(REJECTED_PREFIXES) {
        return Bucket::Rejected;
    }
    if PATH_LIKE.contains(&name) {
        return Bucket::PathLike;
    }
    if SESSION_SCOPED.contains(&name) || IDENTITY.contains(&name) {
        return Bucket::Session;
    }
    if COSMETIC.contains(&name) || starts(COSMETIC_PREFIXES) {
        return Bucket::Cosmetic;
    }
    if starts(DERIVED_PREFIXES) {
        return Bucket::Derived;
    }
    // Um valor que é uma lista de diretórios unida por `:` (ou `;` no Windows)
    // é quase certamente um caminho de busca com um nome que ainda não conhecemos.
    if name.ends_with("PATH") && (value.as_str().contains(':') || value.as_str().contains(';')) {
        return Bucket::PathLike;
    }
    Bucket::User
}

#[derive(Debug, Clone, Default)]
pub struct Classification {
    pub buckets: BTreeMap<Bucket, EnvSet>,
}

impl Classification {
    pub fn importable(&self) -> EnvSet {
        self.set(Bucket::User)
    }
    pub fn set(&self, bucket: Bucket) -> EnvSet {
        self.buckets.get(&bucket).cloned().unwrap_or_default()
    }
}

/// Subtração da base.
///
/// O shell da sondagem herda o ambiente com que o app foi aberto, então a
/// saída crua mistura a configuração do shell do usuário com a herança do
/// próprio app. Subtrair a base isola o que o *shell* contribuiu, mantendo
/// qualquer variável à qual o shell deu outro valor.
pub fn classify_observed(observed: &EnvSet, base: &EnvSet) -> Classification {
    let mut out = Classification::default();
    for (key, value) in observed.iter() {
        if base.get(key) == Some(value) {
            continue;
        }
        out.buckets
            .entry(classify(key, value))
            .or_default()
            .insert(key.clone(), value.clone());
    }
    out
}
