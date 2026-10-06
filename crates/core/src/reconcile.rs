//! Computes what an apply or un-apply must actually do.
//!
//! Pure, because this is where the correctness of un-apply is decided, and it
//! needs to be exhaustively testable without a filesystem.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::{EnvKey, EnvSet, EnvValue, PriorState};

/// The keys HyperEnv currently owns, each paired with the value it had
/// *before* HyperEnv first touched it.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ManagedState {
    baselines: BTreeMap<EnvKey, PriorState>,
}

impl ManagedState {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn managed_keys(&self) -> impl Iterator<Item = &EnvKey> {
        self.baselines.keys()
    }
    pub fn is_empty(&self) -> bool {
        self.baselines.is_empty()
    }
    pub fn is_managed(&self, key: &EnvKey) -> bool {
        self.baselines.contains_key(key)
    }
    pub fn baseline(&self, key: &EnvKey) -> Option<&PriorState> {
        self.baselines.get(key)
    }

    fn capture(&mut self, key: EnvKey, state: PriorState) {
        // Only if absent: re-capturing is the bug this whole type exists to
        // prevent.
        self.baselines.entry(key).or_insert(state);
    }

    fn release(&mut self, key: &EnvKey) {
        self.baselines.remove(key);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// Exactly what the session script should export.
    pub exports: EnvSet,
    /// Keys becoming managed now, with the prior value to remember.
    pub captures: BTreeMap<EnvKey, PriorState>,
    /// Keys no longer wanted, with the value to put back.
    pub restores: BTreeMap<EnvKey, PriorState>,
    /// The managed state after this plan is committed.
    pub resulting_state: ManagedState,
}

impl Plan {
    pub fn is_noop(&self) -> bool {
        self.captures.is_empty() && self.restores.is_empty()
    }

    /// Entries for the inverse script, covering both what we are taking over and
    /// what we are handing back.
    pub fn inverse_entries(&self) -> Vec<(EnvKey, PriorState)> {
        let mut merged = self.captures.clone();
        for (k, v) in &self.restores {
            merged.insert(k.clone(), v.clone());
        }
        merged.into_iter().collect()
    }
}

/// Plans an apply.
///
/// - `desired`: the variables the profile wants exported.
/// - `managed`: what HyperEnv already owns.
/// - `observed`: the user's environment measured *with HyperEnv bypassed*, so
///   it reflects their real configuration rather than our own output.
///
/// The invariant: a key's baseline is captured **once**, on the
/// unmanaged-to-managed transition, and discarded only on the way back. A key
/// we already own is never re-measured — doing so would record our own applied
/// value as though it were the user's original, so a later un-apply would
/// "restore" a value the user never had.
pub fn plan(desired: &EnvSet, managed: &ManagedState, observed: &EnvSet) -> Plan {
    let mut state = managed.clone();
    let mut captures = BTreeMap::new();
    let mut restores = BTreeMap::new();

    for key in desired.keys() {
        if state.is_managed(key) {
            continue;
        }
        let prior = match observed.get(key) {
            Some(v) => PriorState::Present(v.clone()),
            None => PriorState::Absent,
        };
        captures.insert(key.clone(), prior.clone());
        state.capture(key.clone(), prior);
    }

    let dropped: Vec<EnvKey> = state
        .managed_keys()
        .filter(|k| !desired.contains(k))
        .cloned()
        .collect();
    for key in dropped {
        if let Some(baseline) = state.baseline(&key) {
            restores.insert(key.clone(), baseline.clone());
        }
        state.release(&key);
    }

    Plan {
        exports: desired.clone(),
        captures,
        restores,
        resulting_state: state,
    }
}

/// Plans a full un-apply: every managed key goes back to its baseline.
pub fn unapply_plan(managed: &ManagedState) -> Plan {
    let restores = managed.baselines.clone();
    Plan {
        exports: EnvSet::new(),
        captures: BTreeMap::new(),
        restores,
        resulting_state: ManagedState::new(),
    }
}

// ── Drift ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftDetail {
    /// Exported by us, absent from the shell.
    Missing { expected: EnvValue },
    /// Exported by us, but something later assigned a different value.
    Shadowed { expected: EnvValue, actual: EnvValue },
}

/// Compares what the shell actually reports against what we exported.
///
/// Catches the failure a checksum never will: the user adding
/// `export API_URL=…` to their dotfile *after* our block, which silently
/// overrides us while every file still hashes correctly.
pub fn semantic_drift(expected: &EnvSet, observed: &EnvSet) -> BTreeMap<EnvKey, DriftDetail> {
    let mut drift = BTreeMap::new();
    for (key, want) in expected.iter() {
        match observed.get(key) {
            None => {
                drift.insert(
                    key.clone(),
                    DriftDetail::Missing {
                        expected: want.clone(),
                    },
                );
            }
            Some(actual) if actual != want => {
                drift.insert(
                    key.clone(),
                    DriftDetail::Shadowed {
                        expected: want.clone(),
                        actual: actual.clone(),
                    },
                );
            }
            Some(_) => {}
        }
    }
    drift
}
