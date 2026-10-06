//! HyperEnv for Windows and Linux — the window over the same engine as the
//! `hyperenv` command. Builds and runs on macOS too, for development.
//!
//! The UI thread only reads and writes the profiles file, which is fast.
//! Applying, un-applying and drift probe the user's shell (or the registry),
//! which can take a moment, so they run on a worker thread and report back
//! through the event loop — the window never freezes.

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use hyperenv_engine::journal::Transaction;
use hyperenv_engine::probe::{Probe, ShellProbe};
use hyperenv_engine::{Drift, Engine, Error, Layout, Platform, Profile, Store};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};

slint::include_modules!();

struct State {
    layout: Layout,
    store: Store,
    applied: Option<Transaction>,
    selected: Option<String>,
    search: String,
    revealed: HashSet<(String, String)>,
    /// The profile whose delete button was pressed once; a second press deletes.
    confirm_delete: Option<String>,
    /// A message that overrides the computed banner until the next action.
    notice: Option<(i32, String)>,
    drift: Option<usize>,
    busy: bool,
}

/// Runs `f` against the engine for this platform: the registry on Windows,
/// the login shell everywhere else.
fn with_engine<T>(layout: &Layout, f: impl FnOnce(&Engine) -> Result<T, Error>) -> Result<T, Error> {
    #[cfg(windows)]
    {
        let probe = hyperenv_engine::probe::FixedProbe(Default::default());
        let reg = hyperenv_engine::registry::WinRegistry;
        return f(&Engine::with_registry(layout.clone(), &probe, &reg));
    }
    #[allow(unreachable_code)]
    {
        let probe = ShellProbe::default();
        f(&Engine::new(layout.clone(), &probe as &dyn Probe))
    }
}

impl State {
    fn profile(&self) -> Option<&Profile> {
        self.selected.as_deref().and_then(|n| self.store.get(n))
    }

    fn save(&mut self) -> Result<(), Error> {
        self.store.save(&self.layout.profiles_file())
    }

    fn visible(&self) -> Vec<&Profile> {
        let q = self.search.to_lowercase();
        self.store
            .profiles
            .iter()
            .filter(|p| q.is_empty() || p.name.to_lowercase().contains(&q))
            .collect()
    }

    fn target_label(&self) -> String {
        match (self.layout.platform, self.layout.startup_file()) {
            (Platform::Windows, _) | (_, None) => "user environment".into(),
            (_, Some(f)) => {
                format!(
                    "{} · {}",
                    format!("{:?}", self.layout.shell).to_lowercase(),
                    self.layout.display(&f)
                )
            }
        }
    }

    /// Pushes everything the window shows. Cheap: called after every action.
    fn render(&self, ui: &AppWindow) {
        let applied_name = self.applied.as_ref().map(|t| t.profile_name.as_str());
        let visible = self.visible();

        let rows: Vec<ProfileRow> = visible
            .iter()
            .map(|p| {
                let live = applied_name == Some(p.name.as_str());
                ProfileRow {
                    name: p.name.as_str().into(),
                    meta: format!(
                        "{} variables{}",
                        p.variables.len(),
                        if live { " · applied" } else { "" }
                    )
                    .into(),
                    applied: live,
                }
            })
            .collect();
        ui.set_profiles(ModelRc::new(VecModel::from(rows)));
        let index = self
            .selected
            .as_deref()
            .and_then(|n| visible.iter().position(|p| p.name == n));
        ui.set_selected(index.map_or(-1, |i| i as i32));

        let Some(p) = self.profile() else {
            ui.set_vars(ModelRc::new(VecModel::from(Vec::<VarRow>::new())));
            self.render_status(ui, false);
            return;
        };

        let vars: Vec<VarRow> = p
            .variables
            .iter()
            .map(|v| VarRow {
                key: v.key.as_str().into(),
                value: v.value.as_str().into(),
                secret: v.secret,
                enabled: v.enabled,
                revealed: self.revealed.contains(&(p.name.clone(), v.key.to_string())),
            })
            .collect();
        ui.set_vars(ModelRc::new(VecModel::from(vars)));
        ui.set_profile_name(p.name.as_str().into());
        ui.set_profile_meta(
            format!(
                "{} variables · edited {}",
                p.variables.len(),
                short_time(&p.updated_at)
            )
            .into(),
        );

        // Applied and unchanged → Undo. Applied but edited since → it needs a
        // re-apply, so Apply comes back with the pending banner.
        let live = applied_name == Some(p.name.as_str());
        let dirty = live && self.applied.as_ref().is_some_and(|t| t.exports != p.env_set());
        ui.set_is_applied(live && !dirty);

        if let Some((kind, text)) = &self.notice {
            ui.set_banner_kind(*kind);
            ui.set_banner_text(text.as_str().into());
            ui.set_banner_detail("".into());
        } else if dirty {
            ui.set_banner_kind(2);
            ui.set_banner_text("Changed since it was applied. Apply again so new terminals get it.".into());
            ui.set_banner_detail("".into());
        } else if live {
            let t = self.applied.as_ref().unwrap();
            ui.set_banner_kind(1);
            ui.set_banner_text(
                format!(
                    "Active in new terminals since {}. Open ones keep what they had.",
                    short_time(&t.timestamp)
                )
                .into(),
            );
            ui.set_banner_detail(self.target_label().into());
        } else {
            ui.set_banner_kind(0);
        }
        self.render_status(ui, true);
    }

    fn render_status(&self, ui: &AppWindow, _has_profile: bool) {
        ui.set_busy(self.busy);
        ui.set_status_left(
            match &self.applied {
                Some(t) => format!("applied: {} · {}", t.profile_name, self.target_label()),
                None => "nothing applied — original environment".into(),
            }
            .into(),
        );
        ui.set_status_right(
            match self.drift {
                Some(0) => "no drift".into(),
                Some(1) => "1 drift".into(),
                Some(n) => format!("{n} drifts"),
                None => String::new(),
            }
            .into(),
        );
        if self.selected.is_none()
            && let Some((kind, text)) = &self.notice
        {
            ui.set_banner_kind(*kind);
            ui.set_banner_text(text.as_str().into());
        }
    }
}

/// `2026-10-06T03:23:07.123Z` → `03:23` today, or the date otherwise.
fn short_time(rfc3339: &str) -> String {
    let today = hyperenv_engine::now_rfc3339();
    match (rfc3339.get(0..10), rfc3339.get(11..16)) {
        (Some(day), Some(hm)) if today.starts_with(day) => hm.to_owned(),
        (Some(day), _) => day.to_owned(),
        _ => rfc3339.to_owned(),
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let ui = AppWindow::new()?;
    let Some(layout) = Layout::detect() else {
        eprintln!("hyperenv: could not determine the home folder.");
        std::process::exit(1);
    };

    let mut notice = None;
    let store = Store::load(&layout.profiles_file()).unwrap_or_else(|e| {
        notice = Some((3, e.to_string()));
        Store::default()
    });
    let applied = with_engine(&layout, |e| e.current()).ok().flatten();
    let selected = applied
        .as_ref()
        .map(|t| t.profile_name.clone())
        .filter(|n| store.get(n).is_some())
        .or_else(|| store.profiles.first().map(|p| p.name.clone()));

    let state = Rc::new(RefCell::new(State {
        layout,
        store,
        applied,
        selected,
        search: String::new(),
        revealed: HashSet::new(),
        confirm_delete: None,
        notice,
        drift: None,
        busy: false,
    }));
    state.borrow().render(&ui);
    check_drift(&ui, &state);

    // Every handler: mutate the state, then render. `act` clears the
    // one-shot notice first, so a message never outlives the next action.
    fn act(ui: &AppWindow, state: &Rc<RefCell<State>>, f: impl FnOnce(&mut State)) {
        let mut s = state.borrow_mut();
        s.notice = None;
        f(&mut s);
        s.render(ui);
    }

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_select(move |i| {
        let ui = w.unwrap();
        act(&ui, &s, |st| {
            let name = st.visible().get(i as usize).map(|p| p.name.clone());
            st.selected = name;
            st.confirm_delete = None;
        });
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_search_edited(move |text| {
        let ui = w.unwrap();
        act(&ui, &s, |st| st.search = text.to_string());
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_create_profile(move |name| {
        let ui = w.unwrap();
        act(&ui, &s, |st| match st.store.create(&name) {
            Ok(p) => {
                st.selected = Some(p.name.clone());
                st.search.clear();
                if let Err(e) = st.save() {
                    st.notice = Some((3, e.to_string()));
                }
            }
            Err(e) => st.notice = Some((3, e.to_string())),
        });
        ui.set_search("".into());
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_delete_profile(move || {
        let ui = w.unwrap();
        act(&ui, &s, |st| {
            let Some(name) = st.selected.clone() else { return };
            if st.confirm_delete.as_deref() != Some(&name) {
                st.confirm_delete = Some(name.clone());
                st.notice = Some((
                    2,
                    format!("Press delete again to remove \"{name}\" and its variables."),
                ));
                return;
            }
            st.confirm_delete = None;
            match st.store.delete(&name).and_then(|_| st.save()) {
                Ok(()) => st.selected = st.store.profiles.first().map(|p| p.name.clone()),
                Err(e) => st.notice = Some((3, e.to_string())),
            }
        });
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_set_var(move |key, text| {
        let ui = w.unwrap();
        let mut error = String::new();
        act(&ui, &s, |st| {
            let Some(profile) = st.selected.clone() else {
                return;
            };
            // An empty key is the "new variable" row: NAME=value in one field.
            let (key, value) = if key.is_empty() {
                match text.split_once('=') {
                    Some((k, v)) => (k.trim().to_owned(), v.to_owned()),
                    None => {
                        error = "Write it as NAME=value.".into();
                        st.notice = Some((3, error.clone()));
                        return;
                    }
                }
            } else {
                (key.to_string(), text.to_string())
            };
            if let Err(e) = st
                .store
                .set_var(&profile, &key, &value, None)
                .and_then(|_| st.save())
            {
                error = e.to_string();
                st.notice = Some((3, error.clone()));
            }
        });
        SharedString::from(error)
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_delete_var(move |key| {
        let ui = w.unwrap();
        act(&ui, &s, |st| {
            let Some(profile) = st.selected.clone() else {
                return;
            };
            if let Err(e) = st.store.remove_var(&profile, &key).and_then(|_| st.save()) {
                st.notice = Some((3, e.to_string()));
            }
        });
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_toggle_reveal(move |key| {
        let ui = w.unwrap();
        act(&ui, &s, |st| {
            let Some(profile) = st.selected.clone() else {
                return;
            };
            let k = (profile, key.to_string());
            if !st.revealed.remove(&k) {
                st.revealed.insert(k);
            }
        });
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_copy_value(move |key| {
        let ui = w.unwrap();
        act(&ui, &s, |st| {
            let value = st
                .profile()
                .and_then(|p| p.variables.iter().find(|v| v.key.as_str() == key.as_str()))
                .map(|v| v.value.to_string());
            if let Some(value) = value {
                let copied = arboard::Clipboard::new().and_then(|mut c| c.set_text(value));
                st.notice = Some(match copied {
                    Ok(()) => (1, format!("{key} copied.")),
                    Err(e) => (3, format!("Could not copy: {e}")),
                });
            }
        });
    });

    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_apply(move || run_engine(&w.unwrap(), &s, true));
    let (w, s) = (ui.as_weak(), state.clone());
    ui.on_undo(move || run_engine(&w.unwrap(), &s, false));

    ui.run()
}

/// Apply or un-apply on a worker thread, then report back on the UI thread.
fn run_engine(ui: &AppWindow, state: &Rc<RefCell<State>>, apply: bool) {
    let (layout, profile) = {
        let mut s = state.borrow_mut();
        if s.busy {
            return;
        }
        let Some(p) = s.profile().cloned() else { return };
        s.busy = true;
        s.notice = None;
        s.render(ui);
        (s.layout.clone(), p)
    };
    let weak = ui.as_weak();
    std::thread::spawn(move || {
        let result = with_engine(&layout, |e| {
            if apply {
                e.apply(&profile)?;
            } else {
                e.unapply()?;
            }
            e.current()
        });
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|cell| {
                if let Some(state) = cell.borrow().as_ref() {
                    let mut s = state.borrow_mut();
                    s.busy = false;
                    match result {
                        Ok(tx) => {
                            s.applied = tx;
                            s.drift = None;
                        }
                        Err(e) => s.notice = Some((3, e.to_string())),
                    }
                    s.render(&ui);
                }
            });
            if let Some(state) = STATE.with(|c| c.borrow().clone()) {
                check_drift(&ui, &state);
            }
        });
    });
}

thread_local! {
    /// The UI thread's state, reachable from closures that come back through
    /// `invoke_from_event_loop` (which must be `Send` and cannot carry the Rc).
    static STATE: RefCell<Option<Rc<RefCell<State>>>> = const { RefCell::new(None) };
}

/// Asks a fresh terminal whether it gets what was applied — on a worker
/// thread, because it starts the user's login shell.
fn check_drift(ui: &AppWindow, state: &Rc<RefCell<State>>) {
    STATE.with(|c| *c.borrow_mut() = Some(state.clone()));
    let layout = {
        let s = state.borrow();
        if s.applied.is_none() {
            return;
        }
        s.layout.clone()
    };
    let weak = ui.as_weak();
    std::thread::spawn(move || {
        let count = with_engine(&layout, |e| e.drift()).ok().map(|d| {
            d.iter()
                .map(|x| match x {
                    Drift::Semantic(m) => m.len(),
                    _ => 1,
                })
                .sum::<usize>()
        });
        let _ = slint::invoke_from_event_loop(move || {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|cell| {
                if let Some(state) = cell.borrow().as_ref() {
                    let mut s = state.borrow_mut();
                    s.drift = count;
                    s.render(&ui);
                }
            });
        });
    });
}
