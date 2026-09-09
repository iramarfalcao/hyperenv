# The `hyperenv` command

The command-line tool is the one door the editor plugins use, and it is
useful on its own. It opens the **same** SwiftData store and drives the
**same** `ApplyEngine` as the app, so there is one engine, one journal and one
writer to `~/.zprofile` no matter which window pressed the button. Everything
the engine suite proves about the app — journal before dotfile, baseline
captured once, backup once, lock — holds for the command.

It ships inside the app at `HyperEnv.app/Contents/Helpers/hyperenv`. To build
it on its own:

```sh
Scripts/build-cli.sh            # -> build/hyperenv, universal
```

## Grammar

```
hyperenv [--json] <noun> [verb] [options]
```

| Command | What it does |
|---|---|
| `status` | What is applied, the hook's state, drift, orphaned transactions, the reload command |
| `projects` | Every project with its profiles (no variables — ask per profile) |
| `project create <name>` | Trimmed; a blank name is refused |
| `project delete --project <id\|name>` | Refused for Default and for a project holding the applied profile |
| `profile create --project <p> --name <n> [--kind dev\|hml\|prd\|custom]` | Kind defaults to `custom` |
| `profile duplicate --project <p> --profile <f>` | The way a Default snapshot becomes an appliable profile |
| `profile delete --project <p> --profile <f>` | Refused for Default and for the applied profile |
| `vars --project <p> --profile <f>` | The profile's variables, in order. Values are plain; the text form masks secrets |
| `var set … KEY=VALUE [--secret] [--disabled] [--enabled] [--note <t>]` | Creates or updates in place; the first `=` splits, so values may contain `=` |
| `var enable\|disable\|delete … KEY` | |
| `apply --project <p> --profile <f>` | Refused for Default |
| `unapply` | A no-op when nothing is applied |
| `hook install\|remove` | |
| `version` | |

`--project` and `--profile` accept a UUID or an exact name. Two profiles with
the same name make the name an error — the command says to use the id rather
than picking one.

## JSON

With `--json` every result is an envelope on stdout, and the exit status is
`0` or `1`:

```json
{ "ok": true,  "data": { … } }
{ "ok": false, "error": "no project named \"nope\"" }
```

A `nil` field is **absent**, not `null` — `status` has no `applied` key when
nothing is applied. Dates are ISO 8601.

The shapes, as the plugins read them:

```
Project   { id, name, isDefault, folderPath?, sortIndex, profiles: [Profile] }
Profile   { id, name, kind, isDefault, canBeApplied, isApplied, variableCount, enabledCount, sortIndex }
Variable  { id, key, value, isEnabled, isSecret, note?, origin, isValid, sortIndex }
Status    { version, applied?: { projectId, projectName, profileId, profileName, appliedAt, exportedKeys },
            hook: "installed" | "notInstalled" | "malformed", hookDetail?, drift: [String],
            pendingRecoveries, reloadCommand, undoCommand, sessionScript, dotfile, store }
Apply     { applied, exported, captured, restored, reloadCommand }
Unapply   { restored, undoCommand }
```

## Two processes, one store

The app and the command open the same SQLite file. SQLite serialises the
writes; what it does not do is tell the app that something changed. A project
created from a plugin appears in the app after it re-reads — today that means
reopening the window. Making the app watch the store is on the list.

## Checks

`Tests/run-cli-checks.sh` runs the whole grammar against a throwaway store
(`--store`), so the real one is never touched. Apply, un-apply and the hook are
not exercised there — they would write the real `~/.zprofile` — and are proven
by `Tests/run-engine-checks.sh` against an in-memory filesystem instead.
