//! Every path HyperEnv knows about, in a single value — injectable, so tests
//! run in a throwaway HOME without touching the user's.

use std::path::{Path, PathBuf};

use hyperenv_core::render::Shell;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    MacOs,
    Linux,
    Windows,
}

impl Platform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }
}

#[derive(Debug, Clone)]
pub struct Layout {
    pub platform: Platform,
    pub home: PathBuf,
    /// `~/.config/hyperenv` on macOS and Linux (the same as the 1.x app);
    /// `%APPDATA%\hyperenv` on Windows.
    pub config_dir: PathBuf,
    /// The login shell, which decides the dialect and the startup file.
    pub shell: Shell,
    /// That shell's executable, for the probe.
    pub shell_path: PathBuf,
    /// zsh with `ZDOTDIR` pointing elsewhere reads the `.zprofile` there, not
    /// the one in home.
    pub zdotdir: Option<PathBuf>,
}

impl Layout {
    /// The real layout for this account.
    pub fn detect() -> Option<Self> {
        let platform = Platform::current();
        let home = home_dir()?;
        let (shell, shell_path) = login_shell(platform);
        let config_dir = match platform {
            Platform::Windows => std::env::var_os("APPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Roaming"))
                .join("hyperenv"),
            _ => home.join(".config").join("hyperenv"),
        };
        let zdotdir = std::env::var_os("ZDOTDIR")
            .map(PathBuf::from)
            .filter(|d| d.is_dir() && *d != home);
        Some(Self {
            platform,
            home,
            config_dir,
            shell,
            shell_path,
            zdotdir,
        })
    }

    /// Test layout: everything inside `home`.
    pub fn in_home(home: &Path, platform: Platform, shell: Shell, shell_path: impl Into<PathBuf>) -> Self {
        Self {
            platform,
            home: home.to_path_buf(),
            config_dir: home.join(".config").join("hyperenv"),
            shell,
            shell_path: shell_path.into(),
            zdotdir: None,
        }
    }

    pub fn profiles_file(&self) -> PathBuf {
        self.config_dir.join("profiles.json")
    }
    pub fn session_script(&self) -> PathBuf {
        self.config_dir
            .join(format!("session.{}", self.shell.extension()))
    }
    pub fn unsession_script(&self) -> PathBuf {
        self.config_dir
            .join(format!("unsession.{}", self.shell.extension()))
    }
    pub fn journal_dir(&self) -> PathBuf {
        self.config_dir.join("journal")
    }
    pub fn current_journal(&self) -> PathBuf {
        self.journal_dir().join("current.json")
    }
    pub fn history_dir(&self) -> PathBuf {
        self.journal_dir().join("history")
    }
    pub fn backups_dir(&self) -> PathBuf {
        self.config_dir.join("backups")
    }
    pub fn lock_file(&self) -> PathBuf {
        self.config_dir.join("lock")
    }

    /// The user's file that holds the block loading the session.
    ///
    /// - zsh: `~/.zprofile`, not `~/.zshenv` — `/etc/zprofile` runs
    ///   `path_helper`, which reorders PATH, and `.zshenv` runs in *every*
    ///   non-interactive shell, leaking profile credentials into unrelated
    ///   scripts.
    /// - bash on macOS: `~/.bash_profile` (Terminal opens a login shell).
    /// - bash on Linux: `~/.bashrc` — terminal emulators open an interactive
    ///   shell *without* login, which does not read `.bash_profile`.
    /// - fish: `config.fish`, with the same managed block. *Not* `conf.d`:
    ///   fish loads `conf.d` before `config.fish`, and a user's `set -gx` there
    ///   would override the profile (found in the end-to-end test).
    /// - PowerShell (Windows): there is no file; the environment goes through
    ///   the registry.
    pub fn startup_file(&self) -> Option<PathBuf> {
        match (self.shell, self.platform) {
            (Shell::Zsh, _) => Some(self.zdotdir.as_ref().unwrap_or(&self.home).join(".zprofile")),
            (Shell::Bash, Platform::MacOs) => Some(self.home.join(".bash_profile")),
            (Shell::Bash, _) => Some(self.home.join(".bashrc")),
            (Shell::Fish, _) => Some(self.fish_config_dir().join("config.fish")),
            (Shell::PowerShell, _) => None,
        }
    }

    pub fn fish_config_dir(&self) -> PathBuf {
        std::env::var_os("XDG_CONFIG_HOME")
            .filter(|_| self.home == home_dir().unwrap_or_default())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.home.join(".config"))
            .join("fish")
    }

    /// `$HOME`-relative form for writing inside scripts, so the block stays
    /// valid if home is mounted somewhere else.
    pub fn shell_relative(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) => {
                let rest = self.join_for_shell(rest);
                match self.shell {
                    Shell::Fish => format!("$HOME/{rest}"),
                    Shell::PowerShell => format!("$HOME\\{rest}"),
                    _ => format!("${{HOME}}/{rest}"),
                }
            }
            Err(_) => path.to_string_lossy().into_owned(),
        }
    }

    /// `~` form for the interface.
    pub fn display(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) if self.shell == Shell::PowerShell => format!("~\\{}", self.join_for_shell(rest)),
            Ok(rest) => format!("~/{}", self.join_for_shell(rest)),
            Err(_) => path.to_string_lossy().into_owned(),
        }
    }

    /// Joined by hand rather than with to_string_lossy(): on Windows that
    /// yields backslashes, which zsh, bash and fish (Git Bash, MSYS) read as
    /// escapes, not separators. `\` only for PowerShell.
    fn join_for_shell(&self, rest: &Path) -> String {
        let sep = if self.shell == Shell::PowerShell {
            "\\"
        } else {
            "/"
        };
        rest.components()
            .map(|c| c.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join(sep)
    }
}

/// The account's real home. On Unix it comes from the password database, not
/// from `$HOME`: a packaged app may receive a container `$HOME` and send every
/// write to the wrong place.
pub fn home_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        if let Some(dir) = passwd_field(|pw| pw.pw_dir) {
            return Some(PathBuf::from(dir));
        }
    }
    std::env::home_dir()
}

fn login_shell(platform: Platform) -> (Shell, PathBuf) {
    if platform == Platform::Windows {
        return (Shell::PowerShell, PathBuf::from("pwsh"));
    }
    #[cfg(unix)]
    let from_passwd = passwd_field(|pw| pw.pw_shell);
    #[cfg(not(unix))]
    let from_passwd: Option<String> = None;
    // `$SHELL` is inherited and often lies about the real login shell.
    let path = from_passwd
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/zsh".into());
    let shell = Shell::from_path(&path).unwrap_or(Shell::Zsh);
    (shell, PathBuf::from(path))
}

#[cfg(unix)]
fn passwd_field(pick: impl Fn(&libc::passwd) -> *mut libc::c_char) -> Option<String> {
    // SAFETY: getpwuid returns a pointer to static memory that stays valid
    // until the next call; we copy the text before returning.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() {
            return None;
        }
        let field = pick(&*pw);
        if field.is_null() {
            return None;
        }
        Some(std::ffi::CStr::from_ptr(field).to_string_lossy().into_owned())
    }
}
