//! Apply and undo: the only door through which the machine's environment changes.

use std::collections::BTreeMap;

use hyperenv_core::guarded_block::{self as gb, Markers};
use hyperenv_core::reconcile::{self, DriftDetail, ManagedState, Plan};
use hyperenv_core::render;
use hyperenv_core::{EnvKey, EnvSet, PriorState};
use uuid::Uuid;

use crate::journal::{Journal, RegKind, Transaction, TxState};
use crate::layout::Layout;
use crate::probe::Probe;
use crate::registry::Registry;
use crate::store::Profile;
use crate::{Error, fsx, now_rfc3339};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookStatus {
    NotInstalled,
    Installed,
    /// The block exists but is malformed — refuse to guess, offer a repair.
    Malformed(String),
    /// Windows: there is no file; the registry is the target.
    NotNeeded,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Drift {
    /// The generated script was edited by hand.
    SessionEdited,
    /// The block vanished from the startup file while the journal says applied.
    HookMissing,
    /// The shell (or the registry) shows values different from the ones we wrote.
    Semantic(BTreeMap<EnvKey, DriftDetail>),
}

#[derive(Debug, Clone)]
pub struct Outcome {
    pub transaction: Transaction,
    pub plan: Plan,
    /// For an already-open terminal to pick up the profile now.
    pub reload_command: String,
    /// For an already-open terminal to go back to the original.
    pub undo_command: String,
}

/// Where the environment goes.
enum Target<'a> {
    /// macOS and Linux: a session script loaded by the startup file.
    Shell,
    /// Windows: `HKCU\Environment`.
    Registry(&'a dyn Registry),
}

pub struct Engine<'a> {
    pub layout: Layout,
    probe: &'a dyn Probe,
    registry: Option<&'a dyn Registry>,
}

impl<'a> Engine<'a> {
    /// Shell engine (macOS and Linux).
    pub fn new(layout: Layout, probe: &'a dyn Probe) -> Self {
        Self {
            layout,
            probe,
            registry: None,
        }
    }

    /// Registry engine (Windows).
    pub fn with_registry(layout: Layout, probe: &'a dyn Probe, registry: &'a dyn Registry) -> Self {
        Self {
            layout,
            probe,
            registry: Some(registry),
        }
    }

    fn target(&self) -> Target<'a> {
        match self.registry {
            Some(r) => Target::Registry(r),
            None => Target::Shell,
        }
    }

    fn journal(&self) -> Journal<'_> {
        Journal { layout: &self.layout }
    }

    pub fn current(&self) -> Result<Option<Transaction>, Error> {
        self.journal().load_current()
    }

    pub fn reload_command(&self) -> String {
        render::source_command(
            self.layout.shell,
            &self.layout.display(&self.layout.session_script()),
        )
    }

    pub fn undo_command(&self) -> String {
        render::source_command(
            self.layout.shell,
            &self.layout.display(&self.layout.unsession_script()),
        )
    }

    // ── Hook ─────────────────────────────────────────────────────────────────

    pub fn hook_status(&self) -> HookStatus {
        let Some(file) = self.layout.startup_file() else {
            return HookStatus::NotNeeded;
        };
        let read = fsx::resolve_symlink(&file, &self.layout.home).and_then(|f| fsx::read_text_if_exists(&f));
        match read {
            Ok(None) => HookStatus::NotInstalled,
            Ok(Some(text)) => match gb::extract_body(&text, &self.layout.display(&file)) {
                Ok(Some(_)) => HookStatus::Installed,
                Ok(None) => HookStatus::NotInstalled,
                Err(e) => HookStatus::Malformed(e.to_string()),
            },
            Err(e) => HookStatus::Malformed(e.to_string()),
        }
    }

    /// Installs the block that loads the session. Runs once: later applies only
    /// rewrite the session script, and the user's file is not touched again —
    /// that is what keeps the recurring operation safe.
    pub fn install_hook(&self) -> Result<(), Error> {
        let _lock = fsx::Lock::acquire(&self.layout.lock_file())?;
        self.install_hook_locked()
    }

    pub fn remove_hook(&self) -> Result<(), Error> {
        let _lock = fsx::Lock::acquire(&self.layout.lock_file())?;
        let Some(file) = self.layout.startup_file() else {
            return Ok(());
        };
        let file = fsx::resolve_symlink(&file, &self.layout.home)?;
        let Some(text) = fsx::read_text_if_exists(&file)? else {
            return Ok(());
        };
        let updated = gb::remove(&text, &self.layout.display(&file)).map_err(Error::Core)?;
        if updated != text {
            fsx::write_atomic(&file, updated.as_bytes(), None)?;
        }
        Ok(())
    }

    fn hook_body(&self) -> Vec<String> {
        self.layout
            .shell
            .hook_body(&self.layout.shell_relative(&self.layout.session_script()))
    }

    fn install_hook_locked(&self) -> Result<(), Error> {
        let change = self.prepare_hook()?;
        self.write_hook(change)
    }

    /// Reads and computes the change to the startup file without writing
    /// anything. Runs *before* any of the apply's writes: an unreadable file
    /// or a malformed block has to stop everything, not leave an already
    /// swapped session behind.
    fn prepare_hook(&self) -> Result<Option<HookChange>, Error> {
        let Some(file) = self.layout.startup_file() else {
            return Ok(None);
        };
        let file = fsx::resolve_symlink(&file, &self.layout.home)?;
        let existing = fsx::read_text_if_exists(&file)?.unwrap_or_default();
        let updated = gb::install(
            &existing,
            &self.hook_body(),
            &Markers::v1(),
            &self.layout.display(&file),
        )
        .map_err(Error::Core)?;
        Ok(Some(HookChange {
            file,
            existing,
            updated,
        }))
    }

    fn write_hook(&self, change: Option<HookChange>) -> Result<(), Error> {
        let Some(c) = change else { return Ok(()) };
        if c.updated == c.existing {
            return Ok(());
        }
        self.backup_once(&c.file, &c.existing)?;
        fsx::write_atomic(&c.file, c.updated.as_bytes(), None)
    }

    fn hook_hash(&self) -> Result<String, Error> {
        let Some(file) = self.layout.startup_file() else {
            return Ok(String::new());
        };
        let file = fsx::resolve_symlink(&file, &self.layout.home)?;
        let Some(text) = fsx::read_text_if_exists(&file)? else {
            return Ok(String::new());
        };
        let body = gb::extract_body(&text, "").ok().flatten().unwrap_or_default();
        Ok(fsx::sha256(&body.join("\n")))
    }

    /// Keeps an intact copy from before HyperEnv first touched the file.
    /// Backups are never deleted.
    fn backup_once(&self, file: &std::path::Path, content: &str) -> Result<(), Error> {
        if content.is_empty() {
            return Ok(());
        }
        let dir = self.layout.backups_dir();
        let name = file
            .file_name()
            .map(|n| n.to_string_lossy().trim_start_matches('.').to_owned());
        let name = name.unwrap_or_else(|| "startup".into());
        let already = std::fs::read_dir(&dir)
            .map(|d| {
                d.flatten()
                    .any(|e| e.file_name().to_string_lossy().starts_with(&format!("{name}.")))
            })
            .unwrap_or(false);
        if already {
            return Ok(());
        }
        let stamp = now_rfc3339().replace(':', "-");
        fsx::write_atomic(
            &dir.join(format!("{name}.{stamp}.bak")),
            content.as_bytes(),
            Some(0o600),
        )
    }

    // ── Plan ─────────────────────────────────────────────────────────────────

    /// What the user's "original" environment contains, measured without HyperEnv.
    fn observe_original(&self) -> Result<(EnvSet, BTreeMap<EnvKey, RegKind>), Error> {
        match self.target() {
            Target::Shell => Ok((self.probe.observe(&self.layout, true)?, BTreeMap::new())),
            Target::Registry(reg) => {
                let all = reg.read_all()?;
                let kinds = all.iter().map(|(k, (_, kind))| (k.clone(), *kind)).collect();
                Ok((all.into_iter().map(|(k, (v, _))| (k, v)).collect(), kinds))
            }
        }
    }

    /// What an apply would change, without touching anything.
    pub fn plan(&self, profile: &Profile) -> Result<Plan, Error> {
        let (observed, _) = self.observe_original()?;
        let managed = self.current()?.map(|t| t.managed).unwrap_or_default();
        Ok(reconcile::plan(&profile.env_set(), &managed, &observed))
    }

    // ── Apply ────────────────────────────────────────────────────────────────

    pub fn apply(&self, profile: &Profile) -> Result<Outcome, Error> {
        // Measured with HyperEnv switched off, to read the user's real
        // configuration and not our own previous output.
        let (observed, kinds) = self.observe_original()?;
        let _lock = fsx::Lock::acquire(&self.layout.lock_file())?;
        let hook = match self.target() {
            Target::Shell => self.prepare_hook()?,
            Target::Registry(_) => None,
        };

        let existing = self.current()?;
        let managed = existing.as_ref().map(|t| t.managed.clone()).unwrap_or_default();
        let plan = reconcile::plan(&profile.env_set(), &managed, &observed);
        let stamp = now_rfc3339();
        let shell = self.layout.shell;

        let session = render::session(shell, &plan.exports, &profile.name, &stamp);
        let inverse = render::inverse(
            shell,
            &plan.inverse_entries(),
            &stamp,
            &self.layout.display(&self.layout.unsession_script()),
        );

        // The original registry type, pinned together with the original value.
        let mut registry_kinds = existing
            .as_ref()
            .map(|t| t.registry_kinds.clone())
            .unwrap_or_default();
        for key in plan.captures.keys() {
            if let Some(kind) = kinds.get(key) {
                registry_kinds.insert(key.clone(), *kind);
            }
        }
        registry_kinds.retain(|k, _| plan.resulting_state.is_managed(k));

        let mut tx = Transaction {
            format: 2,
            id: Uuid::new_v4(),
            timestamp: stamp,
            profile_id: Some(profile.id),
            profile_name: profile.name.clone(),
            target: match self.target() {
                Target::Shell => format!("{shell:?}").to_lowercase(),
                Target::Registry(_) => "registry".into(),
            },
            managed: plan.resulting_state.clone(),
            exports: plan.exports.clone(),
            session_hash: fsx::sha256(&session),
            hook_hash: String::new(),
            state: TxState::Pending,
            registry_kinds,
        };

        // 1. Intent first, with the originals. If we die after this point,
        //    the next startup can still revert everything.
        self.journal().write_pending(&tx)?;

        // 2. The scripts. The inverse is written *now*, not at undo time, so
        //    it keeps working even if HyperEnv is deleted.
        fsx::write_atomic(&self.layout.session_script(), session.as_bytes(), Some(0o600))?;
        fsx::write_atomic(&self.layout.unsession_script(), inverse.as_bytes(), Some(0o600))?;

        // 3. The actual target.
        match self.target() {
            Target::Shell => {
                self.write_hook(hook)?;
                tx.hook_hash = self.hook_hash()?;
            }
            Target::Registry(reg) => {
                for (key, prior) in &plan.restores {
                    restore_registry(reg, key, prior, managed_kind(&existing, key))?;
                }
                for (key, value) in plan.exports.iter() {
                    let kind = if value.as_str().contains('%') {
                        RegKind::Expand
                    } else {
                        RegKind::String
                    };
                    reg.set(key, value, kind)?;
                }
                reg.broadcast()?;
            }
        }

        // 4. Commit.
        tx.state = TxState::Applied;
        self.journal().commit(&tx)?;

        Ok(Outcome {
            transaction: tx,
            plan,
            reload_command: self.reload_command(),
            undo_command: self.undo_command(),
        })
    }

    // ── Undo ─────────────────────────────────────────────────────────────────

    /// Returns every controlled variable to its previous value.
    pub fn unapply(&self) -> Result<Plan, Error> {
        let _lock = fsx::Lock::acquire(&self.layout.lock_file())?;
        let Some(existing) = self.current()? else {
            return Ok(reconcile::unapply_plan(&ManagedState::new()));
        };
        let plan = reconcile::unapply_plan(&existing.managed);
        let stamp = now_rfc3339();
        let shell = self.layout.shell;

        let inverse = render::inverse(
            shell,
            &plan.inverse_entries(),
            &stamp,
            &self.layout.display(&self.layout.unsession_script()),
        );
        // An empty session rather than a deleted one: the hook checks that it
        // is readable, and keeping the file makes the next apply instant.
        let empty = render::session(shell, &EnvSet::new(), "none", &stamp);
        fsx::write_atomic(&self.layout.unsession_script(), inverse.as_bytes(), Some(0o600))?;
        fsx::write_atomic(&self.layout.session_script(), empty.as_bytes(), Some(0o600))?;

        if let Target::Registry(reg) = self.target() {
            for (key, prior) in &plan.restores {
                restore_registry(reg, key, prior, existing.registry_kinds.get(key).copied())?;
            }
            reg.broadcast()?;
        }

        let mut closing = existing;
        closing.state = TxState::Unapplied;
        closing.managed = ManagedState::new();
        closing.exports = EnvSet::new();
        closing.registry_kinds.clear();
        self.journal().commit(&closing)?;
        self.journal().clear_current()?;
        Ok(plan)
    }

    // ── Recovery and drift ───────────────────────────────────────────────────

    /// Applies written but never committed: a sign of a crash midway.
    pub fn pending(&self) -> Result<Vec<Transaction>, Error> {
        self.journal().pending()
    }

    pub fn discard_pending(&self, id: Uuid) -> Result<(), Error> {
        self.journal().discard_pending(id)
    }

    pub fn drift(&self) -> Result<Vec<Drift>, Error> {
        let Some(applied) = self.current()?.filter(|t| t.state == TxState::Applied) else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        let observed = match self.target() {
            Target::Shell => {
                if let Some(text) = fsx::read_text_if_exists(&self.layout.session_script())?
                    && fsx::sha256(&text) != applied.session_hash
                {
                    out.push(Drift::SessionEdited);
                }
                if self.hook_status() != HookStatus::Installed {
                    out.push(Drift::HookMissing);
                }
                // What a checksum does not catch: the user adding their own
                // `export API_URL=…` after our block.
                self.probe.observe(&self.layout, false)?
            }
            Target::Registry(reg) => reg.read_all()?.into_iter().map(|(k, (v, _))| (k, v)).collect(),
        };
        let semantic = reconcile::semantic_drift(&applied.exports, &observed);
        if !semantic.is_empty() {
            out.push(Drift::Semantic(semantic));
        }
        Ok(out)
    }
}

struct HookChange {
    file: std::path::PathBuf,
    existing: String,
    updated: String,
}

fn managed_kind(existing: &Option<Transaction>, key: &EnvKey) -> Option<RegKind> {
    existing.as_ref().and_then(|t| t.registry_kinds.get(key).copied())
}

fn restore_registry(
    reg: &dyn Registry,
    key: &EnvKey,
    prior: &PriorState,
    kind: Option<RegKind>,
) -> Result<(), Error> {
    match prior {
        PriorState::Absent => reg.delete(key),
        PriorState::Present(v) => reg.set(key, v, kind.unwrap_or(RegKind::String)),
    }
}
