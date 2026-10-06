//! Decides which of the machine's existing variables are safe to import.
//!
//! Everything is bucketed rather than discarded: drift comparison later needs
//! to know a variable was *seen and deliberately excluded*, not merely absent.

use std::collections::BTreeMap;

use crate::types::{EnvKey, EnvSet, EnvValue};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Bucket {
    /// Real user configuration. The only bucket that is importable.
    User,
    /// Produced by tooling rather than authored (`brew shellenv`, etc).
    Derived,
    /// Valid right now, meaningless later. Replaying these points at dead paths.
    Session,
    /// `:`/`;`-separated search paths. Never snapshot wholesale.
    PathLike,
    /// Prompt and terminal bookkeeping.
    Cosmetic,
    /// Refused outright — writing these back would break things.
    Rejected,
}

impl Bucket {
    pub fn is_importable(self) -> bool {
        self == Bucket::User
    }
}

/// Recreated under a different name on every login: never replay.
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
    // Linux (graphical session and systemd)
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

/// Identity of the account itself — never HyperEnv's to manage.
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

/// `DYLD_*` is stripped by SIP for protected processes and setting it can
/// break signed binaries; `LD_PRELOAD` injects code into every process. They
/// are shown but never written.
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
    // A value that is a `:`-joined (`;` on Windows) list of directories is
    // almost certainly a search path under a name we do not know yet.
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

/// Base subtraction.
///
/// The probe shell inherits whatever environment the app was launched with,
/// so the raw output mixes the user's shell configuration with the app's own
/// inheritance. Subtracting the base isolates what the *shell* contributed,
/// while still keeping any variable the shell assigned a different value to.
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
