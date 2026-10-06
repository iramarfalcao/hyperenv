//! HyperEnv's engine: the layer that touches the machine — profiles on disk,
//! session scripts, the shell startup file (macOS and Linux) and the registry
//! (Windows). Every decision about *what* to do comes from `hyperenv-core`.

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
                "{} is not valid UTF-8 (first bad byte at offset {offset}). HyperEnv will not rewrite it, because decoding it lossily would destroy content.",
                path.display()
            ),
            Error::SymlinkOutsideHome { path, resolved } => write!(
                f,
                "{} is a symlink to {}, which is outside your home folder.",
                path.display(),
                resolved.display()
            ),
            Error::Busy(path) => write!(
                f,
                "Another HyperEnv operation is in progress (lock held at {}).",
                path.display()
            ),
            Error::Corrupt { path, detail } => write!(f, "{} could not be read: {detail}", path.display()),
            Error::ProbeTimedOut(s) => write!(f, "Reading your shell environment timed out after {s}s."),
            Error::Unsupported(what) => write!(f, "It is not yet possible to {what}."),
            Error::NoSuchProfile(n) => write!(f, "No profile named \"{n}\"."),
            Error::DuplicateProfile(n) => write!(f, "A profile named \"{n}\" already exists."),
            Error::InvalidProfileName(n) => write!(f, "\"{n}\" is not a valid profile name."),
            Error::InvalidKey(k) => write!(f, "'{k}' is not a valid environment variable name."),
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

/// The current date and time in RFC 3339, UTC.
pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}
