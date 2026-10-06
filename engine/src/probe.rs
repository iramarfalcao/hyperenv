//! Mede o ambiente que o shell do usuário de fato produz.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use hyperenv_core::EnvSet;
use hyperenv_core::probe::{SENTINEL, parse_nul_separated};
use hyperenv_core::render::{BYPASS_VARIABLE, Shell};

use crate::{Error, layout::Layout};

pub trait Probe {
    /// `bypass = true`: o ambiente como se o HyperEnv não estivesse instalado
    /// — é a medida do "original" do usuário. `false`: o que um terminal novo
    /// recebe de fato, para detectar divergência.
    fn observe(&self, layout: &Layout, bypass: bool) -> Result<EnvSet, Error>;
}

/// Roda o shell de login e lê o `env -0`.
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
    /// Base mínima e explícita. Herdar o ambiente do próprio app importaria
    /// ruído (Xcode, XPC) para o perfil do usuário; um `env -i` puro perderia
    /// as poucas que só o sistema fornece — essas passam por nome.
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
        // Impede o framework de prompt de desenhar ou emitir sequências de escape.
        base.push(("TERM".into(), "dumb".into()));
        // Só na home de verdade: numa home de teste o XDG do host apontaria o
        // fish para a configuração real do usuário.
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
        // `-l -i`: o que a pessoa vê num terminal novo, com `.zshrc`/`.bashrc`.
        let script = format!("printf '%s' '{SENTINEL}'; env -0");
        let args: Vec<&str> = match layout.shell {
            Shell::Zsh | Shell::Bash => vec!["-l", "-i", "-c", &script],
            Shell::Fish => vec!["--login", "--interactive", "--command", &script],
            Shell::PowerShell => return Err(Error::Unsupported("sondar o PowerShell".into())),
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
    let mut stdout = child.stdout.take().expect("stdout encanado");
    // Lê numa thread: um shell que imprime muito encheria o pipe e travaria.
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

/// Sondagem fixa, para testes.
pub struct FixedProbe(pub EnvSet);

impl Probe for FixedProbe {
    fn observe(&self, _: &Layout, _: bool) -> Result<EnvSet, Error> {
        Ok(self.0.clone())
    }
}
