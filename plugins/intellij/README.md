# HyperEnv for IntelliJ

<!-- Plugin description -->
Apply a profile of environment variables to every new terminal — and undo it —
from inside the IDE.

A **HyperEnv** tool window lists your profiles, marks the applied one, and shows
the selected profile's variables: secrets masked until you reveal them,
disabled ones dimmed. Create, rename, duplicate and delete profiles; add, edit,
enable/disable, mark secret, copy and delete variables; import a `.env` file or
export one. Press **Apply** and every new terminal, including the IDE's own,
starts with that profile; **Undo** puts each variable back to what it was. For
a terminal that is already open, the reload command is one click away.

The plugin carries no engine of its own: it drives the `hyperenv` command
(HyperEnv 2.0 or later), so the desktop app, this plugin and the VS Code
extension share one store and one journal. Works on macOS, Linux and Windows.
<!-- Plugin description end -->

## What it does

| | |
|---|---|
| Profiles | Flat list; the applied one in bold with ● applied. New, rename, duplicate, delete — delete is disabled for the applied profile and always asks first. |
| Variables | Name and value of the selected profile. Add (paste `NAME=value` straight into the name field), edit value, delete, enable/disable, mark/unmark secret, copy value. Secrets show as `••••••••` until *Reveal Secret Values*; disabled variables are dimmed and tagged *off*. Double-click edits. |
| Apply / Undo | Apply the selected profile (also how an edit to the applied profile reaches new terminals); Undo. The balloon after each carries the command for a terminal that is already open, with a copy button; *Copy Reload Command* is also in the toolbar. |
| Status line | What is applied, or *Nothing applied — original environment*; *Changed since applied* when the selected, applied profile's enabled variables no longer match what Apply exported; drift reported by `hyperenv status` (session script edited, hook missing, a variable missing or shadowed in a new terminal); a damaged hook block; pending recoveries. |
| Files | *Import .env…* merges a file into the selected profile (`hyperenv import`) and reports skipped lines; *Export as .env…* saves `hyperenv export --dialect dotenv`. |

Every call to the command runs on a background queue, one at a time, never on
the UI thread: apply, undo and status start your login shell to see what a new
terminal would get, and that can take a moment.

## Finding the command

In order:

1. the path in *Settings › Tools › HyperEnv*;
2. macOS: `/Applications/HyperEnv.app/Contents/Helpers/hyperenv`, then the same under `~/Applications`;
3. `hyperenv` on your `PATH` (the login shell's PATH, not just the IDE's);
4. where the installers put it: `~/.local/bin/hyperenv` (macOS, Linux) or
   `%LOCALAPPDATA%\Programs\hyperenv\hyperenv.exe` (Windows).

When none is found the tool window says so and shows the install commands:

```sh
curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh   # macOS, Linux
irm https://hyperenv.falcaosl.com/install.ps1 | iex             # Windows (PowerShell)
```

A command older than 2.0 (`hyperenv --json version`) is refused with a message
to update: the 1.x grammar (projects, `--project/--profile`) is gone. The
grammar and JSON shapes are in [`crates/cli/README.md`](../../crates/cli/README.md).

## Building

```sh
./gradlew build            # compiles, runs the tests
./gradlew verifyPlugin     # compatibility against the recommended IDEs
./gradlew runIde           # a sandbox IDE with the plugin loaded
```

The tests cover what can be proven without an IDE:

- `EnvelopeTest`, `AppliedCheckTest` — the envelope and every shape, against
  output captured from the real command (`src/test/resources/fixtures`, from
  2.0.0-alpha.3 run on a throwaway `--home`);
- `CliLocatorTest` — the lookup order on each OS and the version gate;
- `VariableKeyTest` — the name rule and the `NAME=value` split;
- `CliIntegrationTest` — the real command end to end (create, set, list, apply,
  status, unapply, rename, duplicate, import, export, delete) against a temp
  `--home`. It uses `-Dhyperenv.cli=…`, `HYPERENV_CLI`, or the repository's
  `target/release/hyperenv`, and is skipped when none exists.

The tool window itself is exercised with `runIde`.

## Icons

`src/main/resources/icons` holds HyperEnv 2's own icons from `design/icons`,
redrawn at 16×16 (same paths, 24-unit viewBox) with IntelliJ's stroke colours:
`#6C707E` for the light theme and `#CED0D6` in the `_dark` twin.
