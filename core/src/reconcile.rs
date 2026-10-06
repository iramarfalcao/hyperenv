//! O que aplicar ou desfazer precisa de fato fazer.
//!
//! Puro, porque é aqui que se decide se desfazer está certo, e isso tem de ser
//! testado à exaustão sem sistema de arquivos.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::{EnvKey, EnvSet, EnvValue, PriorState};

/// As variáveis que o HyperEnv controla agora, cada uma com o valor que tinha
/// *antes* de o HyperEnv mexer nela pela primeira vez.
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
        // Só se ainda não houver: recapturar é exatamente o bug que este tipo
        // existe para impedir.
        self.baselines.entry(key).or_insert(state);
    }

    fn release(&mut self, key: &EnvKey) {
        self.baselines.remove(key);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// Exatamente o que o script de sessão exporta.
    pub exports: EnvSet,
    /// Variáveis que passam a ser controladas agora, com o valor a lembrar.
    pub captures: BTreeMap<EnvKey, PriorState>,
    /// Variáveis que deixaram de ser pedidas, com o valor a devolver.
    pub restores: BTreeMap<EnvKey, PriorState>,
    /// O estado controlado depois que o plano for gravado.
    pub resulting_state: ManagedState,
}

impl Plan {
    pub fn is_noop(&self) -> bool {
        self.captures.is_empty() && self.restores.is_empty()
    }

    /// Entradas do script inverso: o que estamos assumindo e o que estamos
    /// devolvendo.
    pub fn inverse_entries(&self) -> Vec<(EnvKey, PriorState)> {
        let mut merged = self.captures.clone();
        for (k, v) in &self.restores {
            merged.insert(k.clone(), v.clone());
        }
        merged.into_iter().collect()
    }
}

/// Planeja uma aplicação.
///
/// - `desired`: o que o perfil quer exportado.
/// - `managed`: o que o HyperEnv já controla.
/// - `observed`: o ambiente do usuário medido *com o HyperEnv desligado*, para
///   refletir a configuração dele e não a nossa própria saída.
///
/// A invariante: o valor original de uma variável é capturado **uma vez**, na
/// passagem de não controlada para controlada, e só é descartado na volta.
/// Uma variável que já controlamos nunca é medida de novo — isso gravaria o
/// nosso valor aplicado como se fosse o original do usuário, e desfazer
/// "restauraria" um valor que ele nunca teve.
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

/// Planeja desfazer tudo: cada variável controlada volta ao original.
pub fn unapply_plan(managed: &ManagedState) -> Plan {
    let restores = managed.baselines.clone();
    Plan {
        exports: EnvSet::new(),
        captures: BTreeMap::new(),
        restores,
        resulting_state: ManagedState::new(),
    }
}

// ── Divergência ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftDetail {
    /// Exportamos, e o shell não tem.
    Missing { expected: EnvValue },
    /// Exportamos, mas algo depois atribuiu outro valor.
    Shadowed { expected: EnvValue, actual: EnvValue },
}

/// Compara o que o shell de fato mostra com o que exportamos.
///
/// Pega a falha que um checksum nunca pega: o usuário pôr
/// `export API_URL=…` no dotfile *depois* do nosso bloco, o que nos
/// sobrescreve em silêncio enquanto todo arquivo continua com o hash certo.
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
