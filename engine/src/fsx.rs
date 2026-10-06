//! Escrita no disco com as garantias de que o resto depende.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::Error;

/// Lê como UTF-8 ou recusa. Decodificar com perda trocaria bytes inválidos por
/// U+FFFD, e gravar isso de volta destruiria conteúdo num arquivo que o
/// usuário não esperava que reescrevêssemos.
pub fn read_text_if_exists(path: &Path) -> Result<Option<String>, Error> {
    match fs::read(path) {
        Ok(bytes) => String::from_utf8(bytes).map(Some).map_err(|e| Error::NotUtf8 {
            path: path.to_path_buf(),
            offset: e.utf8_error().valid_up_to(),
        }),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::io(path, e)),
    }
}

/// Grava num temporário na mesma pasta e renomeia por cima: uma queda no meio
/// nunca deixa um `session.zsh` pela metade que quebraria todo shell novo.
///
/// `mode`: `Some` impõe as permissões (0600 nos nossos arquivos); `None`
/// mantém as do arquivo do usuário.
pub fn write_atomic(path: &Path, contents: &[u8], mode: Option<u32>) -> Result<(), Error> {
    let dir = path
        .parent()
        .ok_or_else(|| Error::io(path, io::Error::other("sem pasta-mãe")))?;
    fs::create_dir_all(dir).map_err(|e| Error::io(dir, e))?;
    let tmp = dir.join(format!(".hyperenv-{}.tmp", uuid::Uuid::new_v4()));

    let result = (|| -> io::Result<()> {
        let mut f = File::create(&tmp)?;
        f.write_all(contents)?;
        f.sync_all()?;
        drop(f);
        set_mode(&tmp, mode.or_else(|| existing_mode(path)))?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.map_err(|e| Error::io(path, e))
}

#[cfg(unix)]
fn existing_mode(path: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).ok().map(|m| m.permissions().mode() & 0o7777)
}
#[cfg(not(unix))]
fn existing_mode(_: &Path) -> Option<u32> {
    None
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: Option<u32>) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    match mode {
        Some(m) => fs::set_permissions(path, fs::Permissions::from_mode(m)),
        None => Ok(()),
    }
}
#[cfg(not(unix))]
fn set_mode(_: &Path, _: Option<u32>) -> io::Result<()> {
    Ok(())
}

pub fn remove_if_exists(path: &Path) -> Result<(), Error> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(Error::io(path, e)),
        _ => Ok(()),
    }
}

/// Segue o link antes de escrever.
///
/// Um `~/.zprofile` gerenciado por chezmoi, stow ou yadm é um link para dentro
/// de um repositório de dotfiles. Renomear por cima do link o trocaria por um
/// arquivo comum e desligaria o repositório em silêncio — então escrevemos no
/// destino real. Se o destino sair da home, recusamos.
pub fn resolve_symlink(path: &Path, home: &Path) -> Result<PathBuf, Error> {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return Ok(path.to_path_buf());
    };
    if !meta.file_type().is_symlink() {
        return Ok(path.to_path_buf());
    }
    let resolved = fs::canonicalize(path).map_err(|e| Error::io(path, e))?;
    let home = fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    if !resolved.starts_with(&home) {
        return Err(Error::SymlinkOutsideHome {
            path: path.to_path_buf(),
            resolved,
        });
    }
    Ok(resolved)
}

pub fn sha256(text: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Trava entre processos (app, CLI e plugins aplicando ao mesmo tempo).
pub struct Lock(#[allow(dead_code)] File);

impl Lock {
    pub fn acquire(path: &Path) -> Result<Self, Error> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| Error::io(dir, e))?;
        }
        let file = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)
            .map_err(|e| Error::io(path, e))?;
        match file.try_lock() {
            Ok(()) => Ok(Self(file)),
            Err(_) => Err(Error::Busy(path.to_path_buf())),
        }
    }
}
