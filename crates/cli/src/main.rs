//! `hyperenv` — the app's engine, from the terminal.
//!
//! It is the plugins' single door (VS Code, IntelliJ): one engine, one journal
//! and one writer of the startup file, no matter where the click came from.
//! With `--json` every response is an envelope `{ "ok": true, "data": … }` or
//! `{ "ok": false, "error": "…" }`, and the exit code is 0 or 1.

use std::path::PathBuf;
use std::process::ExitCode;

use hyperenv_core::PriorState;
use hyperenv_core::dotenv::{self, Dialect, Severity};
use hyperenv_core::render::Shell;
#[cfg(windows)]
use hyperenv_engine::probe::FixedProbe;
use hyperenv_engine::probe::{Probe, ShellProbe};
use hyperenv_engine::{Drift, Engine, HookStatus, Layout, Platform, Profile, Store};
use serde_json::{Value, json};

const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
hyperenv — apply and undo batches of environment variables

usage: hyperenv [--json] <command>

  status                          what is applied, hook, drift
  profiles                        list the profiles
  profile create <name>
  profile rename <name> <new>
  profile duplicate <name> <new>
  profile delete <name>
  vars <profile> [--show]         variables (secrets masked without --show)
  var set <profile> KEY=VALUE [--secret | --no-secret]
  var enable|disable|delete <profile> KEY
  import <profile> <file.env>     merge a .env file into the profile
  export <profile> [--dialect posix|dotenv|docker]
  plan <profile>                  what applying would change, changing nothing
  apply <profile>                 every new terminal starts with the profile
  unapply                         return every variable to its previous value
  drift                           does a new terminal match what is applied?
  hook install|remove
  migrate                         bring in profiles from HyperEnv 1.x (macOS)
  version
";

/// A usage error (exit code 2), kept apart from a runtime error (exit code 1).
enum Fail {
    Usage(String),
    Run(String),
}

impl<E: std::fmt::Display> From<E> for Fail {
    fn from(e: E) -> Self {
        Fail::Run(e.to_string())
    }
}

type Out = Result<(Value, String), Fail>;

struct Ctx {
    layout: Layout,
}

impl Ctx {
    fn store(&self) -> Result<Store, Fail> {
        Ok(Store::load(&self.layout.profiles_file())?)
    }

    fn save(&self, store: &Store) -> Result<(), Fail> {
        Ok(store.save(&self.layout.profiles_file())?)
    }

    fn profile(&self, store: &Store, name: &str) -> Result<Profile, Fail> {
        store
            .get(name)
            .cloned()
            .ok_or_else(|| Fail::Run(format!("No profile named \"{name}\".")))
    }

    /// The right engine for the platform: the registry on Windows, the shell elsewhere.
    fn with_engine<T>(&self, f: impl FnOnce(&Engine) -> Result<T, Fail>) -> Result<T, Fail> {
        #[cfg(windows)]
        {
            let probe = FixedProbe(Default::default());
            let reg = hyperenv_engine::registry::WinRegistry;
            return f(&Engine::with_registry(self.layout.clone(), &probe, &reg));
        }
        #[allow(unreachable_code)]
        {
            let probe = ShellProbe::default();
            f(&Engine::new(self.layout.clone(), &probe as &dyn Probe))
        }
    }
}

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let json = take_flag(&mut args, "--json");
    // Only for tests and diagnostics: a throwaway home and its shell.
    let home = take_value(&mut args, "--home");
    let shell = take_value(&mut args, "--shell");

    let layout = match layout(home, shell) {
        Ok(l) => l,
        Err(e) => return finish(json, Err(e)),
    };
    let ctx = Ctx { layout };
    finish(json, run(&ctx, &args))
}

fn layout(home: Option<String>, shell: Option<String>) -> Result<Layout, Fail> {
    let mut layout = match &home {
        Some(h) => {
            let path = PathBuf::from(h);
            Layout::in_home(&path, Platform::current(), Shell::Zsh, "/bin/zsh")
        }
        None => Layout::detect().ok_or_else(|| Fail::Run("Could not determine the home folder.".into()))?,
    };
    if let Some(s) = shell {
        layout.shell = Shell::from_path(&s).ok_or_else(|| Fail::Usage(format!("Unknown shell: {s}.")))?;
        layout.shell_path = PathBuf::from(&s);
    }
    Ok(layout)
}

fn finish(json: bool, result: Out) -> ExitCode {
    match result {
        Ok((data, text)) => {
            if json {
                println!("{}", json!({ "ok": true, "data": data }));
            } else if !text.is_empty() {
                print!("{text}");
                if !text.ends_with('\n') {
                    println!();
                }
            }
            ExitCode::SUCCESS
        }
        Err(Fail::Usage(msg)) | Err(Fail::Run(msg)) if json => {
            println!("{}", json!({ "ok": false, "error": msg }));
            ExitCode::FAILURE
        }
        Err(Fail::Usage(msg)) => {
            eprintln!("hyperenv: {msg}\n\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Fail::Run(msg)) => {
            eprintln!("hyperenv: {msg}");
            ExitCode::FAILURE
        }
    }
}

fn take_flag(args: &mut Vec<String>, flag: &str) -> bool {
    let before = args.len();
    args.retain(|a| a != flag);
    args.len() != before
}

fn take_value(args: &mut Vec<String>, flag: &str) -> Option<String> {
    let i = args.iter().position(|a| a == flag)?;
    args.remove(i);
    (i < args.len()).then(|| args.remove(i))
}

fn arg<'a>(args: &'a [String], i: usize, what: &str) -> Result<&'a str, Fail> {
    args.get(i)
        .map(String::as_str)
        .ok_or_else(|| Fail::Usage(format!("missing {what}")))
}

fn run(ctx: &Ctx, args: &[String]) -> Out {
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a.as_slice() {
        [] | ["help"] | ["--help"] | ["-h"] => Ok((json!({ "usage": USAGE }), USAGE.into())),
        ["version"] | ["--version"] => Ok((json!({ "version": VERSION }), format!("hyperenv {VERSION}"))),
        ["status"] => status(ctx),
        ["profiles"] => profiles(ctx),
        ["profile", "create", ..] => edit(ctx, |s| {
            s.create(arg(args, 2, "the name")?)?;
            Ok(format!("Profile \"{}\" created.", args[2].trim()))
        }),
        ["profile", "rename", ..] => edit(ctx, |s| {
            s.rename(arg(args, 2, "the name")?, arg(args, 3, "the new name")?)?;
            Ok(format!("\"{}\" renamed to \"{}\".", args[2], args[3].trim()))
        }),
        ["profile", "duplicate", ..] => edit(ctx, |s| {
            s.duplicate(arg(args, 2, "the name")?, arg(args, 3, "the new name")?)?;
            Ok(format!("\"{}\" duplicated as \"{}\".", args[2], args[3].trim()))
        }),
        ["profile", "delete", name] => {
            if applied_name(ctx)?.as_deref() == Some(*name) {
                return Err(Fail::Run(format!(
                    "\"{name}\" is applied. Undo it before deleting."
                )));
            }
            edit(ctx, |s| {
                s.delete(name)?;
                Ok(format!("Profile \"{name}\" deleted."))
            })
        }
        ["vars", name, rest @ ..] => vars(ctx, name, rest.contains(&"--show")),
        ["var", "set", name, assignment, rest @ ..] => {
            let (key, value) = assignment
                .split_once('=')
                .ok_or_else(|| Fail::Usage("use KEY=VALUE".into()))?;
            let secret = if rest.contains(&"--secret") {
                Some(true)
            } else if rest.contains(&"--no-secret") {
                Some(false)
            } else {
                None
            };
            edit(ctx, |s| {
                s.set_var(name, key, value, secret)?;
                Ok(format!("{key} set in \"{name}\"."))
            })
        }
        ["var", verb @ ("enable" | "disable"), name, key] => edit(ctx, |s| {
            s.set_enabled(name, key, *verb == "enable")?;
            Ok(format!(
                "{key} {} in \"{name}\".",
                if *verb == "enable" { "enabled" } else { "disabled" }
            ))
        }),
        ["var", "delete", name, key] => edit(ctx, |s| {
            if !s.remove_var(name, key)? {
                return Err(Fail::Run(format!("\"{name}\" has no {key}.")));
            }
            Ok(format!("{key} removed from \"{name}\"."))
        }),
        ["import", name, file] => import(ctx, name, file),
        ["export", name, rest @ ..] => export(ctx, name, rest),
        ["plan", name] => plan(ctx, name),
        ["apply", name] => apply(ctx, name),
        ["unapply"] => unapply(ctx),
        ["drift"] => drift(ctx),
        ["hook", "install"] => ctx.with_engine(|e| {
            e.install_hook()?;
            Ok((json!({ "hook": "installed" }), "Hook installed.".into()))
        }),
        ["hook", "remove"] => ctx.with_engine(|e| {
            e.remove_hook()?;
            Ok((json!({ "hook": "notInstalled" }), "Hook removed.".into()))
        }),
        ["migrate"] => migrate(ctx),
        _ => Err(Fail::Usage(format!("unrecognized command: {}", args.join(" ")))),
    }
}

/// Loads, changes and saves the profiles.
fn edit(ctx: &Ctx, f: impl FnOnce(&mut Store) -> Result<String, Fail>) -> Out {
    let mut store = ctx.store()?;
    let text = f(&mut store)?;
    ctx.save(&store)?;
    Ok((json!({ "message": text }), text))
}

fn applied_name(ctx: &Ctx) -> Result<Option<String>, Fail> {
    ctx.with_engine(|e| Ok(e.current()?.map(|t| t.profile_name)))
}

fn profile_json(p: &Profile, applied: Option<&str>) -> Value {
    json!({
        "id": p.id,
        "name": p.name,
        "variableCount": p.variables.len(),
        "enabledCount": p.variables.iter().filter(|v| v.enabled).count(),
        "isApplied": applied == Some(p.name.as_str()),
        "updatedAt": p.updated_at,
    })
}

fn profiles(ctx: &Ctx) -> Out {
    let store = ctx.store()?;
    let applied = applied_name(ctx)?;
    let data: Vec<Value> = store
        .profiles
        .iter()
        .map(|p| profile_json(p, applied.as_deref()))
        .collect();
    let mut text = String::new();
    if store.profiles.is_empty() {
        text.push_str("No profiles. Create one with: hyperenv profile create <name>\n");
    }
    for p in &store.profiles {
        let mark = if applied.as_deref() == Some(p.name.as_str()) {
            "●"
        } else {
            "○"
        };
        text.push_str(&format!("{mark} {}  ({} variables)\n", p.name, p.variables.len()));
    }
    Ok((json!(data), text))
}

fn vars(ctx: &Ctx, name: &str, show: bool) -> Out {
    let store = ctx.store()?;
    let p = ctx.profile(&store, name)?;
    // In JSON the values always go out in full: the plugin decides how to show them.
    let data: Vec<Value> = p
        .variables
        .iter()
        .map(|v| json!({ "key": v.key, "value": v.value, "isSecret": v.secret, "isEnabled": v.enabled }))
        .collect();
    let width = p
        .variables
        .iter()
        .map(|v| v.key.as_str().len())
        .max()
        .unwrap_or(0);
    let mut text = String::new();
    for v in &p.variables {
        let value = if v.secret && !show {
            "••••••••".to_owned()
        } else {
            v.value.to_string()
        };
        let off = if v.enabled { "" } else { "   (disabled)" };
        text.push_str(&format!("{:width$}  {value}{off}\n", v.key.as_str()));
    }
    Ok((json!(data), text))
}

fn import(ctx: &Ctx, name: &str, file: &str) -> Out {
    let raw = std::fs::read_to_string(file).map_err(|e| Fail::Run(format!("{file}: {e}")))?;
    let decoded = dotenv::decode(&raw, Default::default());
    let mut store = ctx.store()?;
    let count = store.merge(name, &decoded.env_set())?;
    ctx.save(&store)?;
    let notes: Vec<Value> = decoded
        .diagnostics
        .iter()
        .map(|d| json!({ "line": d.line, "severity": if d.severity == Severity::Error { "error" } else { "warning" }, "message": d.message }))
        .collect();
    let mut text = format!("{count} variables imported into \"{name}\".\n");
    for d in &decoded.diagnostics {
        text.push_str(&format!("  line {}: {}\n", d.line, d.message));
    }
    Ok((json!({ "imported": count, "diagnostics": notes }), text))
}

fn export(ctx: &Ctx, name: &str, rest: &[&str]) -> Out {
    let dialect = match rest {
        [] => Dialect::Dotenv,
        ["--dialect", "posix"] => Dialect::PosixShell,
        ["--dialect", "dotenv"] => Dialect::Dotenv,
        ["--dialect", "docker"] => Dialect::Docker,
        _ => return Err(Fail::Usage("--dialect posix|dotenv|docker".into())),
    };
    let store = ctx.store()?;
    let p = ctx.profile(&store, name)?;
    let (text, diags) = dotenv::encode(
        &p.env_set(),
        dialect,
        &[format!("HyperEnv — profile {}", p.name)],
        false,
    );
    for d in &diags {
        eprintln!("hyperenv: {}", d.message);
    }
    Ok((json!({ "text": text }), text))
}

fn plan_json(plan: &hyperenv_core::reconcile::Plan) -> Value {
    let restored: Vec<Value> = plan
        .restores
        .iter()
        .map(|(k, p)| match p {
            PriorState::Absent => json!({ "key": k, "to": null }),
            PriorState::Present(v) => json!({ "key": k, "to": v }),
        })
        .collect();
    json!({
        "exported": plan.exports.keys().collect::<Vec<_>>(),
        "captured": plan.captures.keys().collect::<Vec<_>>(),
        "restored": restored,
    })
}

fn plan(ctx: &Ctx, name: &str) -> Out {
    let store = ctx.store()?;
    let p = ctx.profile(&store, name)?;
    ctx.with_engine(|e| {
        let plan = e.plan(&p)?;
        let mut text = format!(
            "Applying \"{name}\" would export {} variables.\n",
            plan.exports.len()
        );
        for k in plan.captures.keys() {
            text.push_str(&format!("  + {k} (the current value is kept for undo)\n"));
        }
        for k in plan.restores.keys() {
            text.push_str(&format!("  − {k} (goes back to its previous value)\n"));
        }
        Ok((plan_json(&plan), text))
    })
}

fn apply(ctx: &Ctx, name: &str) -> Out {
    let store = ctx.store()?;
    let p = ctx.profile(&store, name)?;
    ctx.with_engine(|e| {
        let out = e.apply(&p)?;
        let mut data = plan_json(&out.plan);
        data["applied"] = json!(p.name);
        data["reloadCommand"] = json!(out.reload_command);
        data["undoCommand"] = json!(out.undo_command);
        let text = if ctx.layout.platform == Platform::Windows {
            format!(
                "\"{name}\" applied: {} variables. Every new terminal starts with them.\n",
                out.plan.exports.len()
            )
        } else {
            format!(
                "\"{name}\" applied: {} variables. Every new terminal starts with them.\nIn this terminal: {}\n",
                out.plan.exports.len(),
                out.reload_command
            )
        };
        Ok((data, text))
    })
}

fn unapply(ctx: &Ctx) -> Out {
    ctx.with_engine(|e| {
        let had = e.current()?.map(|t| t.profile_name);
        let plan = e.unapply()?;
        let mut data = plan_json(&plan);
        data["undoCommand"] = json!(e.undo_command());
        let text = match had {
            None => "Nothing applied.".to_owned(),
            Some(n) => format!(
                "\"{n}\" undone: {} variables back to what they were.\nIn this terminal: {}\n",
                plan.restores.len(),
                e.undo_command()
            ),
        };
        Ok((data, text))
    })
}

fn drift_json(drift: &[Drift]) -> (Value, String) {
    let mut items = Vec::new();
    let mut text = String::new();
    for d in drift {
        match d {
            Drift::SessionEdited => {
                items.push(json!({ "kind": "sessionEdited" }));
                text.push_str("The session script was edited by hand.\n");
            }
            Drift::HookMissing => {
                items.push(json!({ "kind": "hookMissing" }));
                text.push_str("The HyperEnv block is missing from the startup file.\n");
            }
            Drift::Semantic(map) => {
                for (k, detail) in map {
                    use hyperenv_core::reconcile::DriftDetail::*;
                    match detail {
                        Missing { expected } => {
                            items.push(json!({ "kind": "missing", "key": k, "expected": expected }));
                            text.push_str(&format!("{k}: applied, but a new terminal does not have it.\n"));
                        }
                        Shadowed { expected, actual } => {
                            items.push(json!({ "kind": "shadowed", "key": k, "expected": expected, "actual": actual }));
                            text.push_str(&format!("{k}: something after HyperEnv changes the value.\n"));
                        }
                    }
                }
            }
        }
    }
    (json!(items), text)
}

fn drift(ctx: &Ctx) -> Out {
    ctx.with_engine(|e| {
        let (data, text) = drift_json(&e.drift()?);
        Ok((data, if text.is_empty() { "No drift.".into() } else { text }))
    })
}

fn status(ctx: &Ctx) -> Out {
    ctx.with_engine(|e| {
        let tx = e.current()?;
        let hook = e.hook_status();
        let (hook_name, hook_detail) = match &hook {
            HookStatus::Installed => ("installed", None),
            HookStatus::NotInstalled => ("notInstalled", None),
            HookStatus::NotNeeded => ("notNeeded", None),
            HookStatus::Malformed(d) => ("malformed", Some(d.clone())),
        };
        let (drift, drift_text) = match &tx {
            Some(_) => drift_json(&e.drift().unwrap_or_default()),
            None => (json!([]), String::new()),
        };
        let pending = e.pending()?.len();
        let l = &ctx.layout;
        let mut data = json!({
            "version": VERSION,
            "shell": format!("{:?}", l.shell).to_lowercase(),
            "hook": hook_name,
            "drift": drift,
            "pendingRecoveries": pending,
            "reloadCommand": e.reload_command(),
            "undoCommand": e.undo_command(),
            "sessionScript": l.display(&l.session_script()),
            "store": l.display(&l.profiles_file()),
        });
        if let Some(f) = l.startup_file() {
            data["startupFile"] = json!(l.display(&f));
        }
        if let Some(d) = &hook_detail {
            data["hookDetail"] = json!(d);
        }
        let mut text = String::new();
        match &tx {
            Some(t) => {
                data["applied"] = json!({
                    "profileId": t.profile_id,
                    "profileName": t.profile_name,
                    "appliedAt": t.timestamp,
                    "exportedKeys": t.exports.keys().collect::<Vec<_>>(),
                });
                text.push_str(&format!(
                    "● {} applied at {} ({} variables)\n",
                    t.profile_name,
                    t.timestamp,
                    t.exports.len()
                ));
            }
            None => text.push_str("○ Nothing applied — original environment.\n"),
        }
        text.push_str(&format!("  shell: {}", data["shell"].as_str().unwrap_or("")));
        if let Some(f) = l.startup_file() {
            text.push_str(&format!(" · {} ({})", l.display(&f), hook_text(&hook)));
        }
        text.push('\n');
        text.push_str(&drift_text);
        if pending > 0 {
            text.push_str(&format!(
                "  {pending} interrupted apply in the journal.
"
            ));
        }
        Ok((data, text))
    })
}

fn hook_text(h: &HookStatus) -> String {
    match h {
        HookStatus::Installed => "hook installed".into(),
        HookStatus::NotInstalled => "no hook".into(),
        HookStatus::NotNeeded => "registry".into(),
        HookStatus::Malformed(d) => format!("malformed block: {d}"),
    }
}

#[cfg(target_os = "macos")]
fn migrate(ctx: &Ctx) -> Out {
    use hyperenv_engine::migrate;
    let Some(db) = migrate::find_store(&ctx.layout.home) else {
        return Ok((json!({ "profiles": 0 }), "No HyperEnv 1.x data found.".into()));
    };
    let mut store = ctx.store()?;
    let report = migrate::import_swiftdata(&db, &mut store)?;
    ctx.save(&store)?;
    let mut text = format!(
        "{} profiles and {} variables brought in from {}.\nThe old database was not modified.\n",
        report.profiles,
        report.variables,
        ctx.layout.display(&db)
    );
    for s in &report.skipped {
        text.push_str(&format!("  skipped (invalid name): {s}\n"));
    }
    Ok((
        json!({ "profiles": report.profiles, "variables": report.variables, "skipped": report.skipped }),
        text,
    ))
}

#[cfg(not(target_os = "macos"))]
fn migrate(_: &Ctx) -> Out {
    Ok((
        json!({ "profiles": 0 }),
        "Migration is only available on macOS.".into(),
    ))
}
