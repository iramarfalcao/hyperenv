//! The record of what is actually applied on the machine.
//!
//! Plain JSON on disk, deliberately kept apart from the profiles: it describes
//! changes to files (and to the registry) that the app does not own on its
//! own. If the profiles get corrupted, this file and the generated scripts
//! still say how to undo everything — readable in a text editor at 2 a.m.

use std::collections::BTreeMap;
use std::path::PathBuf;

use hyperenv_core::reconcile::ManagedState;
use hyperenv_core::{EnvKey, EnvSet, EnvValue, PriorState};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::{Error, fsx, layout::Layout};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TxState {
    /// Written before touching any file. If it is found at startup, the
    /// previous apply died midway.
    Pending,
    Applied,
    Unapplied,
}

/// How Windows stores the original value: `REG_SZ` or `REG_EXPAND_SZ`.
/// Undoing has to restore the same type, otherwise `%USERPROFILE%\bin` stops
/// expanding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RegKind {
    String,
    Expand,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transaction {
    pub format: u32,
    pub id: Uuid,
    pub timestamp: String,
    pub profile_id: Option<Uuid>,
    pub profile_name: String,
    /// `zsh`, `bash`, `fish` or `registry`.
    pub target: String,
    /// Every variable we control, with its value from before the first touch.
    /// This is what makes undo *restore*, not just delete.
    pub managed: ManagedState,
    /// Exactly what was written.
    pub exports: EnvSet,
    pub session_hash: String,
    pub hook_hash: String,
    pub state: TxState,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub registry_kinds: BTreeMap<EnvKey, RegKind>,
}

pub struct Journal<'a> {
    pub layout: &'a Layout,
}

impl Journal<'_> {
    fn pending_path(&self, id: Uuid) -> PathBuf {
        self.layout.history_dir().join(format!("{id}.pending.json"))
    }
    fn history_path(&self, id: Uuid) -> PathBuf {
        self.layout.history_dir().join(format!("{id}.json"))
    }

    pub fn load_current(&self) -> Result<Option<Transaction>, Error> {
        let path = self.layout.current_journal();
        let Some(text) = fsx::read_text_if_exists(&path)? else {
            return Ok(None);
        };
        parse_any(&text).map(Some).ok_or(Error::Corrupt {
            path,
            detail: "the journal is not in a known format".into(),
        })
    }

    /// Writes the full intent — with the original values — *before* touching
    /// any file, so a crash midway is recoverable.
    pub fn write_pending(&self, tx: &Transaction) -> Result<(), Error> {
        let mut p = tx.clone();
        p.state = TxState::Pending;
        write_json(&self.pending_path(tx.id), &p)
    }

    pub fn commit(&self, tx: &Transaction) -> Result<(), Error> {
        let mut c = tx.clone();
        if c.state == TxState::Pending {
            c.state = TxState::Applied;
        }
        write_json(&self.layout.current_journal(), &c)?;
        write_json(&self.history_path(tx.id), &c)?;
        fsx::remove_if_exists(&self.pending_path(tx.id))
    }

    pub fn clear_current(&self) -> Result<(), Error> {
        fsx::remove_if_exists(&self.layout.current_journal())
    }

    /// Orphans here at startup mean a previous run died between writing the
    /// intent and committing it.
    pub fn pending(&self) -> Result<Vec<Transaction>, Error> {
        let dir = self.layout.history_dir();
        let Ok(entries) = std::fs::read_dir(&dir) else {
            return Ok(Vec::new());
        };
        let mut out: Vec<Transaction> = entries
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".pending.json"))
            .filter_map(|e| std::fs::read_to_string(e.path()).ok())
            .filter_map(|t| parse_any(&t))
            .collect();
        out.sort_by(|a, b| a.timestamp.cmp(&b.timestamp));
        Ok(out)
    }

    pub fn discard_pending(&self, id: Uuid) -> Result<(), Error> {
        fsx::remove_if_exists(&self.pending_path(id))
    }
}

fn write_json(path: &std::path::Path, tx: &Transaction) -> Result<(), Error> {
    let mut text = serde_json::to_string_pretty(tx).expect("a transaction always serializes");
    text.push('\n');
    fsx::write_atomic(path, text.as_bytes(), Some(0o600))
}

/// Reads format 2, or the 1.x (Swift) app's format, converting the latter.
pub fn parse_any(text: &str) -> Option<Transaction> {
    if let Ok(tx) = serde_json::from_str::<Transaction>(text) {
        return Some(tx);
    }
    parse_legacy(&serde_json::from_str(text).ok()?)
}

/// The 1.x app's journal.
///
/// Swift's `JSONEncoder` writes a dictionary whose key is not a `String` as an
/// alternating list `[key, value, key, value]` — that is how `EnvSet` and
/// `ManagedState` came out. The name becomes `project/profile`.
fn parse_legacy(v: &Value) -> Option<Transaction> {
    let id = Uuid::parse_str(v.get("id")?.as_str()?).ok()?;
    let pairs = |field: &Value| -> Option<Vec<(EnvKey, Value)>> {
        let list = match field {
            Value::Array(a) => a.clone(),
            Value::Object(o) => o
                .iter()
                .flat_map(|(k, v)| [Value::String(k.clone()), v.clone()])
                .collect(),
            _ => return None,
        };
        list.chunks(2)
            .map(|c| Some((EnvKey::new(c.first()?.as_str()?)?, c.get(1)?.clone())))
            .collect()
    };

    let mut managed = ManagedState::new();
    let baselines = pairs(v.get("managed")?.get("baselines")?)?;
    // ManagedState can only be built by the reconciler; we rebuild it via a plan.
    let mut observed = EnvSet::new();
    let mut desired = EnvSet::new();
    for (k, state) in &baselines {
        let prior: PriorState = serde_json::from_value(state.clone()).ok()?;
        if let PriorState::Present(val) = prior {
            observed.insert(k.clone(), val);
        }
        desired.insert(k.clone(), EnvValue::default());
    }
    managed = hyperenv_core::reconcile::plan(&desired, &managed, &observed).resulting_state;

    let exports_field = v.get("exports")?;
    let exports_field = exports_field.get("storage").unwrap_or(exports_field);
    let exports: EnvSet = pairs(exports_field)?
        .into_iter()
        .map(|(k, val)| Some((k, EnvValue::new(val.as_str()?))))
        .collect::<Option<_>>()?;

    let project = v.get("projectName").and_then(Value::as_str).unwrap_or("");
    let profile = v.get("profileName").and_then(Value::as_str).unwrap_or("");
    let state = match v.get("state")?.as_str()? {
        "pending" => TxState::Pending,
        "applied" => TxState::Applied,
        _ => TxState::Unapplied,
    };
    Some(Transaction {
        format: 1,
        id,
        timestamp: v
            .get("timestamp")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        profile_id: None,
        profile_name: if project.is_empty() {
            profile.to_owned()
        } else {
            format!("{project}/{profile}")
        },
        target: "zsh".into(),
        managed,
        exports,
        session_hash: v
            .get("sessionScriptHash")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        hook_hash: v
            .get("markerBlockHash")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        state,
        registry_kinds: BTreeMap::new(),
    })
}
