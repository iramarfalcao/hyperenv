//! Todos os caminhos que o HyperEnv conhece, num valor só — injetável, para
//! que os testes rodem num HOME descartável sem tocar no do usuário.

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
    /// `~/.config/hyperenv` no macOS e no Linux (o mesmo do app 1.x);
    /// `%APPDATA%\hyperenv` no Windows.
    pub config_dir: PathBuf,
    /// O shell de login, que decide o dialeto e o arquivo de inicialização.
    pub shell: Shell,
    /// O executável desse shell, para a sondagem.
    pub shell_path: PathBuf,
}

impl Layout {
    /// O layout real desta conta.
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
        Some(Self {
            platform,
            home,
            config_dir,
            shell,
            shell_path,
        })
    }

    /// Layout de teste: tudo dentro de `home`.
    pub fn in_home(home: &Path, platform: Platform, shell: Shell, shell_path: impl Into<PathBuf>) -> Self {
        Self {
            platform,
            home: home.to_path_buf(),
            config_dir: home.join(".config").join("hyperenv"),
            shell,
            shell_path: shell_path.into(),
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

    /// O arquivo do usuário onde vai o bloco que carrega a sessão.
    ///
    /// - zsh: `~/.zprofile`, não `~/.zshenv` — o `/etc/zprofile` roda o
    ///   `path_helper`, que reordena o PATH, e o `.zshenv` roda em *todo* shell
    ///   não interativo, vazando credenciais de perfil para scripts alheios.
    /// - bash no macOS: `~/.bash_profile` (o Terminal abre shell de login).
    /// - bash no Linux: `~/.bashrc` — os emuladores de terminal abrem shell
    ///   interativo *sem* login, que não lê o `.bash_profile`.
    /// - fish: `config.fish`, com o mesmo bloco gerenciado. *Não* `conf.d`: o
    ///   fish carrega o `conf.d` antes do `config.fish`, e um `set -gx` do
    ///   usuário lá passaria por cima do perfil (achado no teste ponta a ponta).
    /// - PowerShell (Windows): não há arquivo; o ambiente vai pelo registro.
    pub fn startup_file(&self) -> Option<PathBuf> {
        match (self.shell, self.platform) {
            (Shell::Zsh, _) => Some(self.home.join(".zprofile")),
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

    /// Forma relativa a `$HOME` para gravar dentro de scripts, para o bloco
    /// continuar válido se a home for montada em outro lugar.
    pub fn shell_relative(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) => {
                let rest = rest.to_string_lossy();
                match self.shell {
                    Shell::Fish => format!("$HOME/{rest}"),
                    Shell::PowerShell => format!("$HOME\\{rest}"),
                    _ => format!("${{HOME}}/{rest}"),
                }
            }
            Err(_) => path.to_string_lossy().into_owned(),
        }
    }

    /// Forma com `~` para a interface.
    pub fn display(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) => format!("~/{}", rest.to_string_lossy()),
            Err(_) => path.to_string_lossy().into_owned(),
        }
    }
}

/// A home real da conta. No Unix vem do banco de senhas, não do `$HOME`: um
/// app empacotado pode receber um `$HOME` de contêiner e mandar toda escrita
/// para o lugar errado.
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
    // O `$SHELL` é herdado e mente com frequência sobre o shell de login real.
    let path = from_passwd
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/zsh".into());
    let shell = Shell::from_path(&path).unwrap_or(Shell::Zsh);
    (shell, PathBuf::from(path))
}

#[cfg(unix)]
fn passwd_field(pick: impl Fn(&libc::passwd) -> *mut libc::c_char) -> Option<String> {
    // SAFETY: getpwuid devolve um ponteiro para memória estática válida até a
    // próxima chamada; copiamos o texto antes de sair.
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
