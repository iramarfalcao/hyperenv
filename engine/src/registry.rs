//! Windows: o ambiente persistente do usuário mora em `HKCU\Environment`.
//!
//! Atrás de um trait para a lógica de aplicar e desfazer ser testada em
//! qualquer sistema com um registro em memória; só o `WinRegistry` fala com o
//! Windows de verdade.

use std::cell::RefCell;
use std::collections::BTreeMap;

use hyperenv_core::{EnvKey, EnvValue};

use crate::Error;
use crate::journal::RegKind;

pub trait Registry {
    fn read_all(&self) -> Result<BTreeMap<EnvKey, (EnvValue, RegKind)>, Error>;
    fn set(&self, key: &EnvKey, value: &EnvValue, kind: RegKind) -> Result<(), Error>;
    fn delete(&self, key: &EnvKey) -> Result<(), Error>;
    /// Avisa os programas abertos (Explorer, terminais) que o ambiente mudou,
    /// para que o *próximo* terminal aberto por eles já nasça com ele.
    fn broadcast(&self) -> Result<(), Error>;
}

/// Registro em memória, para testes.
#[derive(Default)]
pub struct MemRegistry {
    pub values: RefCell<BTreeMap<EnvKey, (EnvValue, RegKind)>>,
    pub broadcasts: RefCell<usize>,
}

impl Registry for MemRegistry {
    fn read_all(&self) -> Result<BTreeMap<EnvKey, (EnvValue, RegKind)>, Error> {
        Ok(self.values.borrow().clone())
    }
    fn set(&self, key: &EnvKey, value: &EnvValue, kind: RegKind) -> Result<(), Error> {
        self.values
            .borrow_mut()
            .insert(key.clone(), (value.clone(), kind));
        Ok(())
    }
    fn delete(&self, key: &EnvKey) -> Result<(), Error> {
        self.values.borrow_mut().remove(key);
        Ok(())
    }
    fn broadcast(&self) -> Result<(), Error> {
        *self.broadcasts.borrow_mut() += 1;
        Ok(())
    }
}

#[cfg(windows)]
pub use win::WinRegistry;

#[cfg(windows)]
mod win {
    use super::*;
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, RegType};
    use winreg::{RegKey, RegValue};

    pub struct WinRegistry;

    fn env_key(write: bool) -> Result<RegKey, Error> {
        let flags = if write { KEY_READ | KEY_WRITE } else { KEY_READ };
        RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey_with_flags("Environment", flags)
            .map_err(|e| Error::io("HKCU\\Environment", e))
    }

    fn to_utf16z(s: &str) -> Vec<u8> {
        s.encode_utf16()
            .chain(std::iter::once(0))
            .flat_map(u16::to_le_bytes)
            .collect()
    }

    impl Registry for WinRegistry {
        fn read_all(&self) -> Result<BTreeMap<EnvKey, (EnvValue, RegKind)>, Error> {
            let mut out = BTreeMap::new();
            for item in env_key(false)?.enum_values().flatten() {
                let (name, raw) = item;
                let kind = match raw.vtype {
                    RegType::REG_SZ => RegKind::String,
                    RegType::REG_EXPAND_SZ => RegKind::Expand,
                    _ => continue,
                };
                let Some(key) = EnvKey::new(name) else { continue };
                let units: Vec<u16> = raw
                    .bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .collect();
                let text = String::from_utf16_lossy(&units).trim_end_matches('\0').to_owned();
                out.insert(key, (EnvValue::new(text), kind));
            }
            Ok(out)
        }

        fn set(&self, key: &EnvKey, value: &EnvValue, kind: RegKind) -> Result<(), Error> {
            let vtype = match kind {
                RegKind::String => RegType::REG_SZ,
                RegKind::Expand => RegType::REG_EXPAND_SZ,
            };
            env_key(true)?
                .set_raw_value(
                    key.as_str(),
                    &RegValue {
                        bytes: to_utf16z(value.as_str()),
                        vtype,
                    },
                )
                .map_err(|e| Error::io("HKCU\\Environment", e))
        }

        fn delete(&self, key: &EnvKey) -> Result<(), Error> {
            match env_key(true)?.delete_value(key.as_str()) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(Error::io("HKCU\\Environment", e)),
                _ => Ok(()),
            }
        }

        fn broadcast(&self) -> Result<(), Error> {
            use windows_sys::Win32::UI::WindowsAndMessaging::{
                HWND_BROADCAST, SMTO_ABORTIFHUNG, SendMessageTimeoutW, WM_SETTINGCHANGE,
            };
            let param: Vec<u16> = "Environment".encode_utf16().chain(std::iter::once(0)).collect();
            let mut result = 0usize;
            // SAFETY: mensagem de broadcast padrão; o texto vive até o fim da chamada.
            unsafe {
                SendMessageTimeoutW(
                    HWND_BROADCAST,
                    WM_SETTINGCHANGE,
                    0,
                    param.as_ptr() as isize,
                    SMTO_ABORTIFHUNG,
                    5000,
                    &mut result,
                );
            }
            Ok(())
        }
    }
}
