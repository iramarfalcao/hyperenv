//! Os perfis: uma lista plana, num JSON legível.
//!
//! Sem projeto por cima — cada perfil é um lote de variáveis com nome
//! (`api-producao`, `web-local`). Arquivo simples de propósito: o app, o CLI e
//! os plugins leem o mesmo, e ele sobrevive a reinstalação e cabe num diff.

use std::path::Path;

use hyperenv_core::{EnvKey, EnvSet, EnvValue};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{Error, fsx, now_rfc3339};

pub const FORMAT_VERSION: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Variable {
    pub key: EnvKey,
    pub value: EnvValue,
    /// Só muda a exibição (valor mascarado). Não é cofre: o valor fica no
    /// arquivo como os outros, e é escrito no script de sessão igual.
    #[serde(default)]
    pub secret: bool,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub id: Uuid,
    pub name: String,
    pub variables: Vec<Variable>,
    pub created_at: String,
    pub updated_at: String,
}

impl Profile {
    /// O que aplicar exporta: as variáveis ligadas.
    pub fn env_set(&self) -> EnvSet {
        self.variables
            .iter()
            .filter(|v| v.enabled)
            .map(|v| (v.key.clone(), v.value.clone()))
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Store {
    pub version: u32,
    pub profiles: Vec<Profile>,
}

impl Default for Store {
    fn default() -> Self {
        Self {
            version: FORMAT_VERSION,
            profiles: Vec::new(),
        }
    }
}

impl Store {
    pub fn load(path: &Path) -> Result<Self, Error> {
        match fsx::read_text_if_exists(path)? {
            None => Ok(Self::default()),
            Some(text) => {
                let store: Store = serde_json::from_str(&text).map_err(|e| Error::Corrupt {
                    path: path.into(),
                    detail: e.to_string(),
                })?;
                if store.version > FORMAT_VERSION {
                    return Err(Error::Corrupt {
                        path: path.into(),
                        detail: format!("formato {} é de uma versão mais nova do HyperEnv", store.version),
                    });
                }
                Ok(store)
            }
        }
    }

    pub fn save(&self, path: &Path) -> Result<(), Error> {
        let mut text = serde_json::to_string_pretty(self).expect("store sempre serializa");
        text.push('\n');
        fsx::write_atomic(path, text.as_bytes(), Some(0o600))
    }

    pub fn get(&self, name_or_id: &str) -> Option<&Profile> {
        self.profiles
            .iter()
            .find(|p| p.name == name_or_id || p.id.to_string() == name_or_id)
    }

    fn get_mut(&mut self, name: &str) -> Result<&mut Profile, Error> {
        self.profiles
            .iter_mut()
            .find(|p| p.name == name || p.id.to_string() == name)
            .ok_or_else(|| Error::NoSuchProfile(name.to_owned()))
    }

    /// Nome livre, sem repetir (ignorando maiúsculas) e sem espaço nas pontas.
    fn check_name(&self, name: &str, except: Option<Uuid>) -> Result<String, Error> {
        let name = name.trim();
        if name.is_empty() || name.contains(['\n', '\r', '/', '\\']) {
            return Err(Error::InvalidProfileName(name.to_owned()));
        }
        if self
            .profiles
            .iter()
            .any(|p| Some(p.id) != except && p.name.eq_ignore_ascii_case(name))
        {
            return Err(Error::DuplicateProfile(name.to_owned()));
        }
        Ok(name.to_owned())
    }

    pub fn create(&mut self, name: &str) -> Result<&Profile, Error> {
        let name = self.check_name(name, None)?;
        let now = now_rfc3339();
        self.profiles.push(Profile {
            id: Uuid::new_v4(),
            name,
            variables: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        });
        Ok(self.profiles.last().unwrap())
    }

    pub fn rename(&mut self, from: &str, to: &str) -> Result<(), Error> {
        let id = self
            .get(from)
            .ok_or_else(|| Error::NoSuchProfile(from.to_owned()))?
            .id;
        let to = self.check_name(to, Some(id))?;
        let p = self.get_mut(from)?;
        p.name = to;
        p.updated_at = now_rfc3339();
        Ok(())
    }

    pub fn duplicate(&mut self, from: &str, to: &str) -> Result<(), Error> {
        let source = self
            .get(from)
            .ok_or_else(|| Error::NoSuchProfile(from.to_owned()))?
            .clone();
        let to = self.check_name(to, None)?;
        let now = now_rfc3339();
        self.profiles.push(Profile {
            id: Uuid::new_v4(),
            name: to,
            created_at: now.clone(),
            updated_at: now,
            ..source
        });
        Ok(())
    }

    pub fn delete(&mut self, name: &str) -> Result<Profile, Error> {
        let idx = self
            .profiles
            .iter()
            .position(|p| p.name == name || p.id.to_string() == name)
            .ok_or_else(|| Error::NoSuchProfile(name.to_owned()))?;
        Ok(self.profiles.remove(idx))
    }

    /// Cria ou troca o valor de uma variável, mantendo a posição se já existir.
    pub fn set_var(
        &mut self,
        profile: &str,
        key: &str,
        value: &str,
        secret: Option<bool>,
    ) -> Result<(), Error> {
        let key = EnvKey::new(key).ok_or_else(|| Error::InvalidKey(key.to_owned()))?;
        let p = self.get_mut(profile)?;
        match p.variables.iter_mut().find(|v| v.key == key) {
            Some(v) => {
                v.value = EnvValue::new(value);
                if let Some(s) = secret {
                    v.secret = s;
                }
            }
            None => {
                let secret = secret.unwrap_or_else(|| looks_secret(key.as_str()));
                p.variables.push(Variable {
                    key,
                    value: EnvValue::new(value),
                    secret,
                    enabled: true,
                })
            }
        }
        p.updated_at = now_rfc3339();
        Ok(())
    }

    pub fn remove_var(&mut self, profile: &str, key: &str) -> Result<bool, Error> {
        let p = self.get_mut(profile)?;
        let before = p.variables.len();
        p.variables.retain(|v| v.key.as_str() != key);
        let removed = p.variables.len() != before;
        if removed {
            p.updated_at = now_rfc3339();
        }
        Ok(removed)
    }

    pub fn set_enabled(&mut self, profile: &str, key: &str, enabled: bool) -> Result<(), Error> {
        let p = self.get_mut(profile)?;
        let v = p
            .variables
            .iter_mut()
            .find(|v| v.key.as_str() == key)
            .ok_or_else(|| Error::InvalidKey(key.into()))?;
        v.enabled = enabled;
        p.updated_at = now_rfc3339();
        Ok(())
    }

    /// Junta um lote (de um `.env`, por exemplo) ao perfil. O lote vence nas
    /// chaves repetidas; nomes com cara de segredo já entram mascarados.
    pub fn merge(&mut self, profile: &str, incoming: &EnvSet) -> Result<usize, Error> {
        let p = self.get_mut(profile)?;
        for (key, value) in incoming.iter() {
            match p.variables.iter_mut().find(|v| &v.key == key) {
                Some(v) => v.value = value.clone(),
                None => p.variables.push(Variable {
                    key: key.clone(),
                    value: value.clone(),
                    secret: looks_secret(key.as_str()),
                    enabled: true,
                }),
            }
        }
        p.updated_at = now_rfc3339();
        Ok(incoming.len())
    }
}

/// Nome com cara de credencial começa mascarado na interface.
pub fn looks_secret(key: &str) -> bool {
    let k = key.to_ascii_uppercase();
    [
        "SECRET",
        "TOKEN",
        "PASSWORD",
        "PASSWD",
        "PRIVATE",
        "API_KEY",
        "APIKEY",
        "CREDENTIAL",
        "DSN",
        "DATABASE_URL",
    ]
    .iter()
    .any(|w| k.contains(w))
}
