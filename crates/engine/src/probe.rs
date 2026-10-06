//! Measures the environment the user's shell actually produces.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use hyperenv_core::EnvSet;
use hyperenv_core::probe::{SENTINEL, parse_nul_separated};
use hyperenv_core::render::{BYPASS_VARIABLE, Shell};

use crate::{
    Error,
    layout::{Layout, Platform},
};

pub trait Probe {
    /// `bypass = true`: the environment as if HyperEnv were not installed —
    /// the measure of the user's "original". `false`: what a new terminal
    /// actually receives, for detecting drift.
    fn observe(&self, layout: &Layout, bypass: bool) -> Result<EnvSet, Error>;
}

/// Runs the login shell and reads `env -0`.
pub struct ShellProbe {
    pub timeout: Duration,
}

impl Default for ShellProbe {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(5),
        }
    }
}

impl ShellProbe {
    /// A minimal, explicit base. Inheriting the app's own environment would
    /// import noise (Xcode, XPC) into the user's profile; a bare `env -i` would
    /// lose the few variables only the system provides — those pass by name.
    fn base(layout: &Layout) -> Vec<(String, String)> {
        let mut base: Vec<(String, String)> = [
            "USER",
            "LOGNAME",
            "TMPDIR",
            "SSH_AUTH_SOCK",
            "LANG",
            "__CF_USER_TEXT_ENCODING",
            "XDG_RUNTIME_DIR",
        ]
        .iter()
        .filter_map(|n| std::env::var(n).ok().map(|v| (n.to_string(), v)))
        .collect();
        base.push(("HOME".into(), layout.home.to_string_lossy().into_owned()));
        base.push(("SHELL".into(), layout.shell_path.to_string_lossy().into_owned()));
        base.push(("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into()));
        // Stops prompt frameworks from drawing or emitting escape sequences.
        base.push(("TERM".into(), "dumb".into()));
        // Only in the real home: in a test home the host's XDG would point
        // fish at the user's real configuration.
        if Some(&layout.home) == crate::layout::home_dir().as_ref()
            && let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        {
            base.push(("XDG_CONFIG_HOME".into(), xdg));
        }
        base
    }
}

impl Probe for ShellProbe {
    fn observe(&self, layout: &Layout, bypass: bool) -> Result<EnvSet, Error> {
        // `-l -i`: what the person sees in a new terminal, with `.zshrc`/`.bashrc`.
        let script = format!("printf '%s' '{SENTINEL}'; env -0");
        let args: Vec<&str> = match layout.shell {
            // bash on Linux is the exception: terminal emulators start it
            // interactive but *not* as a login shell, so it reads ~/.bashrc
            // (where the hook goes) and not ~/.bash_profile. Probing it as a
            // login shell measured a different environment from the one the
            // user's terminals actually get.
            Shell::Bash if layout.platform == Platform::Linux => vec!["-i", "-c", &script],
            Shell::Zsh | Shell::Bash => vec!["-l", "-i", "-c", &script],
            Shell::Fish => vec!["--login", "--interactive", "--command", &script],
            Shell::PowerShell => return Err(Error::Unsupported("probe PowerShell".into())),
        };
        let mut cmd = Command::new(&layout.shell_path);
        cmd.args(&args)
            .env_clear()
            .envs(Self::base(layout))
            .current_dir(&layout.home);
        if bypass {
            cmd.env(BYPASS_VARIABLE, "1");
        }
        let out = run_with_timeout(cmd, self.timeout)?;
        parse_nul_separated(&out).map_err(Error::Core)
    }
}

fn run_with_timeout(mut cmd: Command, timeout: Duration) -> Result<Vec<u8>, Error> {
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error::io(cmd.get_program(), e))?;
    let mut stdout = child.stdout.take().expect("stdout is piped");
    // Read on a thread: a shell that prints a lot would fill the pipe and hang.
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let start = Instant::now();
    loop {
        if child.try_wait().map_err(|e| Error::io("shell", e))?.is_some() {
            break;
        }
        if start.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::ProbeTimedOut(timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(reader.join().unwrap_or_default())
}

/// A fixed probe, for tests.
pub struct FixedProbe(pub EnvSet);

impl Probe for FixedProbe {
    fn observe(&self, _: &Layout, _: bool) -> Result<EnvSet, Error> {
        Ok(self.0.clone())
    }
}
