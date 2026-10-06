//! Foundational value types: name, value, set and prior state.
//!
//! Pure and free of I/O, so they can cross threads and be exercised by tests
//! without touching the filesystem.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

// ── EnvKey ───────────────────────────────────────────────────────────────────

/// A validated environment variable name.
///
/// POSIX allows `[A-Za-z_][A-Za-z0-9_]*`. `env` can *report* names outside that
/// set, but `export` cannot *write* them — emitting one would produce a script
/// that fails to load, so invalid names are rejected at the type level rather
/// than discovered at apply time.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EnvKey(String);

impl EnvKey {
    pub fn new(raw: impl Into<String>) -> Option<Self> {
        let raw = raw.into();
        Self::is_valid(&raw).then_some(Self(raw))
    }

    /// ASCII-only on purpose: locale-aware character classes would accept names
    /// the shell cannot actually export.
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
        EnvKey::new(raw.clone()).ok_or_else(|| {
            serde::de::Error::custom(format!("'{raw}' is not a valid environment variable name"))
        })
    }
}

// ── EnvValue ─────────────────────────────────────────────────────────────────

/// An environment variable value. Any text is legal except NUL, which
/// separates records in `env -0` output and cannot survive a round trip.
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

/// A set of variables that always iterates in sorted name order.
///
/// Determinism is not cosmetic: exported `.env` files get committed to git, and
/// an unstable order turns every export into a noisy diff.
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

    /// Right-hand side wins, matching shell semantics where the last assignment
    /// takes effect.
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

/// What a variable looked like *before* HyperEnv touched it.
///
/// Deliberately not `Option<EnvValue>`. An empty string and an unset variable
/// are different states in a shell, and un-apply has to reproduce the
/// difference — collapsing them would silently turn `export FOO=` into
/// `unset FOO`.
///
/// Written to JSON with an explicit tag (`{"state":"present","value":""}`), the
/// same shape the Swift app's journal uses.
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

// ── Errors ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    InvalidKey(String),
    UnbalancedMarkers { path: String, detail: String },
    ProbeSentinelMissing,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidKey(k) => write!(f, "'{k}' is not a valid environment variable name."),
            Error::UnbalancedMarkers { path, detail } => write!(
                f,
                "The HyperEnv block in {path} is malformed ({detail}). HyperEnv will not guess where it ends."
            ),
            Error::ProbeSentinelMissing => {
                f.write_str("Could not find the output marker while reading your shell environment.")
            }
        }
    }
}

impl std::error::Error for Error {}
