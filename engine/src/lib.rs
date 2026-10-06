//! Motor do HyperEnv: a camada que toca a máquina — perfis em disco, scripts
//! de sessão, o arquivo de inicialização do shell (macOS e Linux) e o registro
//! (Windows). Toda decisão de *o que* fazer vem do `hyperenv-core`.

use std::fmt;
use std::path::{Path, PathBuf};

pub mod engine;
pub mod fsx;
pub mod journal;
pub mod layout;
#[cfg(target_os = "macos")]
pub mod migrate;
pub mod probe;
pub mod registry;
pub mod store;

pub use engine::{Drift, Engine, HookStatus, Outcome};
pub use layout::{Layout, Platform};
pub use store::{Profile, Store, Variable};

#[derive(Debug)]
pub enum Error {
    Io { path: PathBuf, source: std::io::Error },
    NotUtf8 { path: PathBuf, offset: usize },
    SymlinkOutsideHome { path: PathBuf, resolved: PathBuf },
    Busy(PathBuf),
    Corrupt { path: PathBuf, detail: String },
    ProbeTimedOut(u64),
    Unsupported(String),
    NoSuchProfile(String),
    DuplicateProfile(String),
    InvalidProfileName(String),
    InvalidKey(String),
    Core(hyperenv_core::Error),
}

impl Error {
    pub fn io(path: impl AsRef<Path>, source: std::io::Error) -> Self {
        Error::Io {
            path: path.as_ref().to_path_buf(),
            source,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Error::NotUtf8 { path, offset } => write!(
                f,
                "{} não é UTF-8 válido (primeiro byte ruim na posição {offset}). O HyperEnv não vai reescrevê-lo, porque decodificar com perda destruiria conteúdo.",
                path.display()
            ),
            Error::SymlinkOutsideHome { path, resolved } => write!(
                f,
                "{} é um link para {}, fora da sua pasta pessoal.",
                path.display(),
                resolved.display()
            ),
            Error::Busy(path) => write!(
                f,
                "Outra operação do HyperEnv está em andamento (trava em {}).",
                path.display()
            ),
            Error::Corrupt { path, detail } => write!(f, "{} não pôde ser lido: {detail}", path.display()),
            Error::ProbeTimedOut(s) => write!(f, "Ler o ambiente do shell passou de {s}s."),
            Error::Unsupported(what) => write!(f, "Ainda não é possível {what}."),
            Error::NoSuchProfile(n) => write!(f, "Não existe perfil \"{n}\"."),
            Error::DuplicateProfile(n) => write!(f, "Já existe um perfil \"{n}\"."),
            Error::InvalidProfileName(n) => write!(f, "\"{n}\" não serve como nome de perfil."),
            Error::InvalidKey(k) => write!(f, "'{k}' não é um nome de variável válido."),
            Error::Core(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for Error {}

impl From<hyperenv_core::Error> for Error {
    fn from(e: hyperenv_core::Error) -> Self {
        Error::Core(e)
    }
}

/// Data e hora em RFC 3339, UTC.
pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}
