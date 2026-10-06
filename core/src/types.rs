//! Os tipos de valor do núcleo: nome, valor, conjunto e estado anterior.
//!
//! Puros e sem I/O, para atravessar threads e para serem testados sem tocar
//! no sistema de arquivos.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

// ── EnvKey ───────────────────────────────────────────────────────────────────

/// Nome de variável validado.
///
/// POSIX permite `[A-Za-z_][A-Za-z0-9_]*`. O `env` pode *mostrar* nomes fora
/// disso, mas o `export` não consegue *escrevê-los* — emitir um geraria um
/// script que não carrega. Por isso o nome inválido é recusado no tipo, e não
/// descoberto na hora de aplicar.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EnvKey(String);

impl EnvKey {
    pub fn new(raw: impl Into<String>) -> Option<Self> {
        let raw = raw.into();
        Self::is_valid(&raw).then_some(Self(raw))
    }

    /// Só ASCII, de propósito: classes de caractere sensíveis a locale
    /// aceitariam nomes que o shell não exporta.
    pub fn is_valid(candidate: &str) -> bool {
        let mut bytes = candidate.bytes();
        match bytes.next() {
            Some(b) if b.is_ascii_alphabetic() || b == b'_' => {}
            _ => return false,
        }
        bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for EnvKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Serialize for EnvKey {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for EnvKey {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        EnvKey::new(raw.clone())
            .ok_or_else(|| serde::de::Error::custom(format!("'{raw}' não é um nome de variável válido")))
    }
}

// ── EnvValue ─────────────────────────────────────────────────────────────────

/// Valor de variável. Qualquer texto vale, menos NUL, que separa registros na
/// saída do `env -0` e não sobrevive à ida e volta.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct EnvValue(String);

impl EnvValue {
    pub fn new(raw: impl Into<String>) -> Self {
        Self(raw.into())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn contains_newline(&self) -> bool {
        self.0.contains(['\n', '\r'])
    }
}

impl From<&str> for EnvValue {
    fn from(s: &str) -> Self {
        Self(s.to_owned())
    }
}

impl fmt::Display for EnvValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

// ── EnvSet ───────────────────────────────────────────────────────────────────

/// Conjunto de variáveis que sempre itera em ordem de nome.
///
/// Determinismo não é cosmético: o `.env` exportado vai para o git, e uma
/// ordem instável vira diff barulhento a cada exportação.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct EnvSet(BTreeMap<EnvKey, EnvValue>);

impl EnvSet {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn get(&self, key: &EnvKey) -> Option<&EnvValue> {
        self.0.get(key)
    }
    pub fn insert(&mut self, key: EnvKey, value: EnvValue) {
        self.0.insert(key, value);
    }
    pub fn remove(&mut self, key: &EnvKey) -> Option<EnvValue> {
        self.0.remove(key)
    }
    pub fn contains(&self, key: &EnvKey) -> bool {
        self.0.contains_key(key)
    }
    pub fn keys(&self) -> impl Iterator<Item = &EnvKey> {
        self.0.keys()
    }
    pub fn iter(&self) -> impl Iterator<Item = (&EnvKey, &EnvValue)> {
        self.0.iter()
    }
    pub fn len(&self) -> usize {
        self.0.len()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// O da direita vence, como no shell: a última atribuição vale.
    pub fn merging(&self, other: &EnvSet) -> EnvSet {
        let mut out = self.clone();
        for (k, v) in other.iter() {
            out.insert(k.clone(), v.clone());
        }
        out
    }
}

impl FromIterator<(EnvKey, EnvValue)> for EnvSet {
    fn from_iter<I: IntoIterator<Item = (EnvKey, EnvValue)>>(iter: I) -> Self {
        Self(iter.into_iter().collect())
    }
}

// ── PriorState ───────────────────────────────────────────────────────────────

/// Como a variável estava *antes* do HyperEnv mexer nela.
///
/// Não é `Option<EnvValue>` de propósito. String vazia e variável ausente são
/// estados diferentes no shell, e desfazer tem de reproduzir a diferença —
/// juntar os dois transformaria `export FOO=` em `unset FOO`.
///
/// No JSON vai com etiqueta explícita (`{"state":"present","value":""}`), o
/// mesmo formato do journal do app Swift.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "state", content = "value", rename_all = "lowercase")]
pub enum PriorState {
    Absent,
    Present(EnvValue),
}

impl PriorState {
    pub fn value(&self) -> Option<&EnvValue> {
        match self {
            PriorState::Absent => None,
            PriorState::Present(v) => Some(v),
        }
    }
}

// ── Erros ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    InvalidKey(String),
    UnbalancedMarkers { path: String, detail: String },
    ProbeSentinelMissing,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidKey(k) => write!(f, "'{k}' não é um nome de variável válido."),
            Error::UnbalancedMarkers { path, detail } => write!(
                f,
                "O bloco do HyperEnv em {path} está malformado ({detail}). O HyperEnv não vai adivinhar onde ele termina."
            ),
            Error::ProbeSentinelMissing => {
                f.write_str("Não achei o marcador de saída ao ler o ambiente do shell.")
            }
        }
    }
}

impl std::error::Error for Error {}
