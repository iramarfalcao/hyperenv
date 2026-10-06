# `hyperenv` 2 — the command

The app's engine (`hyperenv-engine`), from the terminal, on macOS, Linux and
Windows. It is the plugins' single door: one engine, one journal and one writer
of the startup file, no matter where the click came from.

```sh
cargo build --release -p hyperenv-cli   # -> target/release/hyperenv
```

## Commands

```
hyperenv [--json] <command>

status                          what is applied, hook, drift
profiles                        list the profiles
profile create|delete <name>
profile rename|duplicate <name> <new>
vars <profile> [--show]         secrets masked without --show
var set <profile> KEY=VALUE [--secret | --no-secret]
var enable|disable|delete <profile> KEY
import <profile> <file.env>
export <profile> [--dialect posix|dotenv|docker]
plan <profile>                  what applying would change, changing nothing
apply <profile>
unapply
drift
hook install|remove
migrate                         profiles from HyperEnv 1.x (macOS)
version
```

Profiles are a flat list: there is no more `--project`/`--profile`. The first
`=` in `KEY=VALUE` splits, so the value may contain `=`.

## JSON

With `--json` every response is an envelope, and the exit code is 0 or 1
(without `--json`, a usage error exits with 2):

```json
{ "ok": true,  "data": { … } }
{ "ok": false, "error": "No profile named \"nope\"." }
```

A missing field is **absent**, not `null` — `status` has no `applied` when
nothing is applied. In JSON the values always go out in full (the plugin decides
how to show secrets).

```
Profile  { id, name, variableCount, enabledCount, isApplied, updatedAt }
Variable { key, value, isSecret, isEnabled }
Status   { version, shell, hook: installed|notInstalled|notNeeded|malformed, hookDetail?,
           applied?: { profileId, profileName, appliedAt, exportedKeys },
           drift: [{ kind, key?, expected?, actual? }], pendingRecoveries,
           reloadCommand, undoCommand, sessionScript, startupFile?, store }
Plan     { exported, captured, restored: [{ key, to }] }   — `to: null` = goes back to not existing
Apply    Plan + { applied, reloadCommand, undoCommand }
```

## Performance

A 2.3 MB binary; a read command takes ~2.4 ms; applying 200 variables, including
the real zsh probe, ~40 ms (Apple Silicon, release).

## Tests

`cargo test -p hyperenv-cli` runs the whole grammar against a throwaway home
(`--home`), including a real apply and undo in zsh.
