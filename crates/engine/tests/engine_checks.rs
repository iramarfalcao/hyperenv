//! The engine against a throwaway home: profiles, apply, undo, hook, journal,
//! in-memory registry and the 1.x migration. Nothing here touches the real
//! home.

use std::fs;
use std::path::Path;

use hyperenv_core::guarded_block::Markers;
use hyperenv_core::render::Shell;
use hyperenv_core::{EnvKey, EnvSet, EnvValue, PriorState};
use hyperenv_engine::journal::{self, RegKind};
use hyperenv_engine::probe::FixedProbe;
use hyperenv_engine::registry::{MemRegistry, Registry};
use hyperenv_engine::{Drift, Engine, Error, HookStatus, Layout, Platform, Store, fsx};

fn key(k: &str) -> EnvKey {
    EnvKey::new(k).unwrap()
}

fn set(pairs: &[(&str, &str)]) -> EnvSet {
    pairs.iter().map(|(k, v)| (key(k), EnvValue::from(*v))).collect()
}

fn layout(home: &Path, shell: Shell) -> Layout {
    Layout::in_home(home, Platform::MacOs, shell, "/bin/zsh")
}

fn profile(store: &mut Store, name: &str, vars: &[(&str, &str)]) -> hyperenv_engine::Profile {
    store.create(name).unwrap();
    for (k, v) in vars {
        store.set_var(name, k, v, None).unwrap();
    }
    store.get(name).unwrap().clone()
}

#[test]
fn credentials_in_a_url_are_secret() {
    use hyperenv_engine::store::has_credentials;
    assert!(has_credentials("postgres://api:s3nh4@10.0.4.12:5432/api"));
    assert!(has_credentials("redis://:token@10.0.4.20:6379/0"));
    assert!(!has_credentials("https://errors.example.com/5"));
    assert!(
        !has_credentials("https://user@host/x"),
        "a user name alone is not a secret"
    );
    assert!(
        !has_credentials("https://host/path?q=a:b@c"),
        "only the authority counts"
    );
    let mut s = Store::default();
    s.create("p").unwrap();
    s.set_var("p", "REDIS_URL", "redis://:token@h:6379/0", None)
        .unwrap();
    assert!(s.get("p").unwrap().variables[0].secret);
}

/// HYPERENV_HOME must not follow the caller's ZDOTDIR into the real home.
#[cfg(unix)]
#[test]
fn hyperenv_home_ignores_the_callers_zdotdir() {
    let fake = tempfile::tempdir().unwrap();
    let real_zdotdir = tempfile::tempdir().unwrap();
    // SAFETY: only this test reads these variables, and the suite runs
    // single-threaded in CI.
    unsafe {
        std::env::set_var("HYPERENV_HOME", fake.path());
        std::env::set_var("ZDOTDIR", real_zdotdir.path());
    }
    let layout = Layout::detect().unwrap();
    unsafe {
        std::env::remove_var("HYPERENV_HOME");
        std::env::remove_var("ZDOTDIR");
    }
    assert_eq!(layout.home, fake.path());
    assert!(layout.config_dir.starts_with(fake.path()));
    if layout.shell == Shell::Zsh {
        assert_eq!(layout.startup_file().unwrap(), fake.path().join(".zprofile"));
    }
}

// ── Profiles ─────────────────────────────────────────────────────────────────

#[test]
fn store_crud_and_persistence() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("profiles.json");
    let mut s = Store::default();
    s.create("api-local").unwrap();
    assert!(matches!(s.create("API-LOCAL"), Err(Error::DuplicateProfile(_))));
    assert!(matches!(s.create("  "), Err(Error::InvalidProfileName(_))));
    s.set_var("api-local", "DATABASE_URL", "postgres://x", None)
        .unwrap();
    s.set_var("api-local", "PORT", "8080", None).unwrap();
    s.set_var("api-local", "PORT", "9090", None).unwrap();
    assert!(matches!(
        s.set_var("api-local", "9X", "v", None),
        Err(Error::InvalidKey(_))
    ));
    s.duplicate("api-local", "api-prod").unwrap();
    s.rename("api-prod", "api-production").unwrap();
    s.set_enabled("api-production", "PORT", false).unwrap();
    s.save(&path).unwrap();

    let back = Store::load(&path).unwrap();
    assert_eq!(back, s);
    let local = back.get("api-local").unwrap();
    assert_eq!(local.variables.len(), 2);
    assert!(local.variables[0].secret, "DATABASE_URL looks like a secret");
    assert!(!local.variables[1].secret);
    assert_eq!(local.env_set().get(&key("PORT")).unwrap().as_str(), "9090");
    assert!(
        back.get("api-production")
            .unwrap()
            .env_set()
            .get(&key("PORT"))
            .is_none(),
        "a disabled variable is not exported"
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn store_merge_from_dotenv() {
    let mut s = Store::default();
    s.create("p").unwrap();
    s.set_var("p", "A", "old", None).unwrap();
    let incoming =
        hyperenv_core::dotenv::decode("A=new\nSTRIPE_SECRET_KEY=sk\n", Default::default()).env_set();
    assert_eq!(s.merge("p", &incoming).unwrap(), 2);
    let p = s.get("p").unwrap();
    assert_eq!(p.env_set().get(&key("A")).unwrap().as_str(), "new");
    assert!(
        p.variables
            .iter()
            .find(|v| v.key.as_str() == "STRIPE_SECRET_KEY")
            .unwrap()
            .secret
    );
}

// ── Apply and undo (shell) ───────────────────────────────────────────────────

#[test]
fn apply_writes_session_hook_and_journal_then_unapply_restores() {
    let home = tempfile::tempdir().unwrap();
    let zprofile = home.path().join(".zprofile");
    let original = "eval \"$(/opt/homebrew/bin/brew shellenv)\"\nexport API_URL='https://prod'\n";
    fs::write(&zprofile, original).unwrap();

    let probe = FixedProbe(set(&[("API_URL", "https://prod")]));
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    let mut store = Store::default();
    let dev = profile(
        &mut store,
        "dev",
        &[("API_URL", "https://dev"), ("NEW_VAR", "it's")],
    );

    assert_eq!(engine.hook_status(), HookStatus::NotInstalled);
    let out = engine.apply(&dev).unwrap();
    assert_eq!(engine.hook_status(), HookStatus::Installed);

    let z = fs::read_to_string(&zprofile).unwrap();
    assert!(z.starts_with(original), "the user's content is intact");
    assert!(z.contains("${HOME}/.config/hyperenv/session.zsh"));

    let session = fs::read_to_string(engine.layout.session_script()).unwrap();
    assert!(session.contains("export API_URL='https://dev'"));
    assert!(session.contains("export NEW_VAR='it'\\''s'"));
    let unsession = fs::read_to_string(engine.layout.unsession_script()).unwrap();
    assert!(unsession.contains("export API_URL='https://prod'") && unsession.contains("unset NEW_VAR"));
    assert_eq!(out.reload_command, "source ~/.config/hyperenv/session.zsh");

    let tx = engine.current().unwrap().unwrap();
    assert_eq!(tx.profile_name, "dev");
    assert_eq!(
        tx.managed.baseline(&key("API_URL")),
        Some(&PriorState::Present("https://prod".into()))
    );
    assert!(engine.pending().unwrap().is_empty());

    // An intact backup from before the first touch.
    let backups: Vec<_> = fs::read_dir(engine.layout.backups_dir())
        .unwrap()
        .flatten()
        .collect();
    assert_eq!(backups.len(), 1);
    assert_eq!(fs::read_to_string(backups[0].path()).unwrap(), original);

    let undo = engine.unapply().unwrap();
    assert_eq!(undo.restores.get(&key("NEW_VAR")), Some(&PriorState::Absent));
    assert!(engine.current().unwrap().is_none());
    assert!(
        !fs::read_to_string(engine.layout.session_script())
            .unwrap()
            .contains("export")
    );

    engine.remove_hook().unwrap();
    assert_eq!(
        fs::read_to_string(&zprofile).unwrap(),
        original,
        "removing the hook gives back the same bytes"
    );
}

#[test]
fn second_apply_keeps_the_true_original() {
    let home = tempfile::tempdir().unwrap();
    let mut store = Store::default();
    let a = profile(&mut store, "a", &[("API_URL", "https://dev")]);
    let b = profile(&mut store, "b", &[("API_URL", "https://hml")]);

    let original = FixedProbe(set(&[("API_URL", "https://prod")]));
    Engine::new(layout(home.path(), Shell::Zsh), &original)
        .apply(&a)
        .unwrap();
    // The probe would now see A's value — it must not become the "original".
    let polluted = FixedProbe(set(&[("API_URL", "https://dev")]));
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &polluted);
    engine.apply(&b).unwrap();
    let undo = engine.unapply().unwrap();
    assert_eq!(
        undo.restores.get(&key("API_URL")),
        Some(&PriorState::Present("https://prod".into()))
    );
}

#[test]
fn bash_and_fish_targets() {
    let home = tempfile::tempdir().unwrap();
    let probe = FixedProbe(EnvSet::new());
    let mut store = Store::default();
    let p = profile(&mut store, "p", &[("X", "1")]);

    let bash = Engine::new(layout(home.path(), Shell::Bash), &probe);
    bash.apply(&p).unwrap();
    assert!(
        fs::read_to_string(home.path().join(".bash_profile"))
            .unwrap()
            .contains("session.bash")
    );
    let mut zdot = layout(home.path(), Shell::Zsh);
    zdot.zdotdir = Some(home.path().join("zsh"));
    assert_eq!(zdot.startup_file().unwrap(), home.path().join("zsh/.zprofile"));
    let linux = Layout::in_home(home.path(), Platform::Linux, Shell::Bash, "/bin/bash");
    assert_eq!(linux.startup_file().unwrap(), home.path().join(".bashrc"));
    bash.unapply().unwrap();

    let fish = Engine::new(layout(home.path(), Shell::Fish), &probe);
    fish.apply(&p).unwrap();
    let conf = home.path().join(".config/fish/config.fish");
    assert!(
        fs::read_to_string(&conf)
            .unwrap()
            .contains("source \"$HOME/.config/hyperenv/session.fish\"")
    );
    assert!(
        fs::read_to_string(fish.layout.session_script())
            .unwrap()
            .contains("set -gx X '1'")
    );
    fish.remove_hook().unwrap();
    assert_eq!(fs::read_to_string(&conf).unwrap(), "", "block removed");
}

#[cfg(unix)]
#[test]
fn symlinked_startup_file_is_written_through_and_outside_home_refused() {
    let home = tempfile::tempdir().unwrap();
    let dotfiles = home.path().join("dotfiles");
    fs::create_dir(&dotfiles).unwrap();
    fs::write(dotfiles.join("zprofile"), "# mine\n").unwrap();
    std::os::unix::fs::symlink(dotfiles.join("zprofile"), home.path().join(".zprofile")).unwrap();

    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    engine.install_hook().unwrap();
    assert!(
        fs::symlink_metadata(home.path().join(".zprofile"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(
        fs::read_to_string(dotfiles.join("zprofile"))
            .unwrap()
            .contains("hyperenv managed block")
    );

    let other = tempfile::tempdir().unwrap();
    let home2 = tempfile::tempdir().unwrap();
    fs::write(other.path().join("z"), "").unwrap();
    std::os::unix::fs::symlink(other.path().join("z"), home2.path().join(".zprofile")).unwrap();
    let e2 = Engine::new(layout(home2.path(), Shell::Zsh), &probe);
    assert!(matches!(e2.install_hook(), Err(Error::SymlinkOutsideHome { .. })));
}

#[test]
fn malformed_block_is_refused() {
    let home = tempfile::tempdir().unwrap();
    fs::write(
        home.path().join(".zprofile"),
        format!("{}\nno end\n", Markers::v1().begin),
    )
    .unwrap();
    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    assert!(matches!(engine.hook_status(), HookStatus::Malformed(_)));
    let mut store = Store::default();
    assert!(engine.apply(&profile(&mut store, "p", &[("X", "1")])).is_err());
}

#[test]
fn concurrent_operation_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    let _held = fsx::Lock::acquire(&engine.layout.lock_file()).unwrap();
    let mut store = Store::default();
    assert!(matches!(
        engine.apply(&profile(&mut store, "p", &[("X", "1")])),
        Err(Error::Busy(_))
    ));
}

#[test]
fn drift_detection() {
    let home = tempfile::tempdir().unwrap();
    let mut store = Store::default();
    let p = profile(&mut store, "p", &[("A", "1"), ("B", "2")]);
    let original = FixedProbe(EnvSet::new());
    Engine::new(layout(home.path(), Shell::Zsh), &original)
        .apply(&p)
        .unwrap();

    // A new terminal shows B overridden by the user.
    let shell_now = FixedProbe(set(&[("A", "1"), ("B", "overridden")]));
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &shell_now);
    let drift = engine.drift().unwrap();
    assert!(matches!(drift.as_slice(), [Drift::Semantic(m)] if m.contains_key(&key("B"))));

    fs::write(engine.layout.session_script(), "# tampered\n").unwrap();
    assert!(engine.drift().unwrap().contains(&Drift::SessionEdited));
}

#[test]
fn unreadable_startup_file_stops_before_any_write() {
    let home = tempfile::tempdir().unwrap();
    let mut store = Store::default();
    let p = profile(&mut store, "p", &[("X", "1")]);
    fs::write(home.path().join(".zprofile"), [0xff, 0xfe, b'\n']).unwrap();
    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    assert!(matches!(engine.apply(&p), Err(Error::NotUtf8 { .. })));
    assert!(!engine.layout.session_script().exists(), "nothing written");
    assert!(engine.pending().unwrap().is_empty());
}

#[test]
fn pending_transaction_is_visible_after_a_crash() {
    let home = tempfile::tempdir().unwrap();
    let mut store = Store::default();
    let p = profile(&mut store, "p", &[("X", "1")]);
    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::new(layout(home.path(), Shell::Zsh), &probe);
    let tx = engine.apply(&p).unwrap().transaction;
    // Simulates a crash between writing the intent and committing it.
    journal::Journal {
        layout: &engine.layout,
    }
    .write_pending(&tx)
    .unwrap();
    let pending = engine.pending().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].profile_name, "p");
    engine.discard_pending(pending[0].id).unwrap();
    assert!(engine.pending().unwrap().is_empty());
}

// ── Windows (in-memory registry) ─────────────────────────────────────────────

#[test]
fn registry_apply_and_unapply_restore_value_and_kind() {
    let home = tempfile::tempdir().unwrap();
    let reg = MemRegistry::default();
    reg.set(&key("JAVA_HOME"), &"%USERPROFILE%\\jdk".into(), RegKind::Expand)
        .unwrap();
    reg.set(&key("KEEP"), &"x".into(), RegKind::String).unwrap();

    let lay = Layout::in_home(home.path(), Platform::Windows, Shell::PowerShell, "pwsh");
    let probe = FixedProbe(EnvSet::new());
    let engine = Engine::with_registry(lay, &probe, &reg);
    assert_eq!(engine.hook_status(), HookStatus::NotNeeded);

    let mut store = Store::default();
    let p = profile(
        &mut store,
        "p",
        &[("JAVA_HOME", "C:\\jdk21"), ("NEW_VAR", "%TEMP%\\x")],
    );
    engine.apply(&p).unwrap();
    {
        let v = reg.values.borrow();
        assert_eq!(v[&key("JAVA_HOME")], ("C:\\jdk21".into(), RegKind::String));
        assert_eq!(v[&key("NEW_VAR")], ("%TEMP%\\x".into(), RegKind::Expand));
    }
    assert_eq!(*reg.broadcasts.borrow(), 1);
    assert!(
        fs::read_to_string(engine.layout.session_script())
            .unwrap()
            .contains("$env:JAVA_HOME = 'C:\\jdk21'")
    );

    engine.unapply().unwrap();
    let v = reg.values.borrow();
    assert_eq!(
        v[&key("JAVA_HOME")],
        ("%USERPROFILE%\\jdk".into(), RegKind::Expand),
        "the original type comes back"
    );
    assert!(!v.contains_key(&key("NEW_VAR")));
    assert_eq!(v[&key("KEEP")], ("x".into(), RegKind::String));
    assert_eq!(*reg.broadcasts.borrow(), 2);
}

// ── 1.x journal ──────────────────────────────────────────────────────────────

#[test]
fn legacy_swift_journal_is_understood() {
    let legacy = r#"{
      "id": "6F1C2A4E-1B7D-4F43-9E7B-0D1C2B3A4F5E",
      "timestamp": "2026-09-01T12:00:00Z",
      "target": "zshStartupFile",
      "projectID": "11111111-1111-1111-1111-111111111111",
      "projectName": "api",
      "profileID": "22222222-2222-2222-2222-222222222222",
      "profileName": "dev",
      "managed": { "baselines": ["API_URL", {"state":"present","value":"https://prod"}, "NEW_VAR", {"state":"absent"}] },
      "exports": { "storage": ["API_URL", "https://dev", "NEW_VAR", "1"] },
      "sessionScriptHash": "abc",
      "markerBlockHash": "def",
      "state": "applied"
    }"#;
    let tx = journal::parse_any(legacy).expect("1.x format");
    assert_eq!(tx.profile_name, "api/dev");
    assert_eq!(
        tx.managed.baseline(&key("API_URL")),
        Some(&PriorState::Present("https://prod".into()))
    );
    assert_eq!(tx.managed.baseline(&key("NEW_VAR")), Some(&PriorState::Absent));
    assert_eq!(tx.exports.get(&key("API_URL")).unwrap().as_str(), "https://dev");

    // Undoing from the old journal restores the original.
    let home = tempfile::tempdir().unwrap();
    let lay = layout(home.path(), Shell::Zsh);
    fs::create_dir_all(lay.journal_dir()).unwrap();
    fs::write(lay.current_journal(), legacy).unwrap();
    let probe = FixedProbe(EnvSet::new());
    let undo = Engine::new(lay, &probe).unapply().unwrap();
    assert_eq!(
        undo.restores.get(&key("API_URL")),
        Some(&PriorState::Present("https://prod".into()))
    );
}

// ── SwiftData migration ──────────────────────────────────────────────────────

#[cfg(target_os = "macos")]
#[test]
fn swiftdata_migration() {
    use hyperenv_engine::migrate;
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("default.store");
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch(
        "CREATE TABLE ZPROJECT (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZISDEFAULT INTEGER, ZSORTINDEX INTEGER);
         CREATE TABLE ZPROFILE (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZISDEFAULT INTEGER, ZSORTINDEX INTEGER, ZPROJECT INTEGER, ZKINDRAW TEXT);
         CREATE TABLE ZENVVARIABLE (Z_PK INTEGER PRIMARY KEY, ZKEY TEXT, ZVALUE TEXT, ZISENABLED INTEGER, ZISSECRET INTEGER, ZSORTINDEX INTEGER, ZPROFILE INTEGER);
         INSERT INTO ZPROJECT VALUES (1,'Default',1,0),(2,'api',0,1),(3,'web',0,2);
         INSERT INTO ZPROFILE VALUES (1,'Default',1,0,1,'default'),(2,'dev',0,0,2,'dev'),(3,'prd',0,1,2,'prd'),(4,'dev',0,0,3,'dev');
         INSERT INTO ZENVVARIABLE VALUES
           (1,'HOME','/x',1,0,0,1),
           (2,'API_URL','https://dev',1,0,0,2),(3,'TOKEN','s3',1,1,1,2),(4,'bad-key','x',1,0,2,2),
           (5,'API_URL','https://prod',1,0,0,3),(6,'OFF','x',0,0,1,3),
           (7,'NEXT_PUBLIC_API','https://dev',1,0,0,4);",
    )
    .unwrap();
    drop(conn);

    assert!(migrate::is_hyperenv_store(&db));
    let mut store = Store::default();
    store.create("api · dev").unwrap(); // name already taken
    let report = migrate::import_swiftdata(&db, &mut store).unwrap();
    assert_eq!(report.profiles, 3, "Default is left out");
    assert_eq!(report.skipped, ["api · dev (2): bad-key"]);
    let names: Vec<&str> = store.profiles.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["api · dev", "api · dev (2)", "api · prd", "web · dev"]);
    let dev = store.get("api · dev (2)").unwrap();
    assert!(
        dev.variables
            .iter()
            .find(|v| v.key.as_str() == "TOKEN")
            .unwrap()
            .secret
    );
    assert!(
        store
            .get("api · prd")
            .unwrap()
            .env_set()
            .get(&key("OFF"))
            .is_none()
    );
}
