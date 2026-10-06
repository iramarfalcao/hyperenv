# HyperEnv for VS Code

Apply a profile of environment variables to every new terminal, and undo it,
from inside VS Code.

![Profiles in the HyperEnv view, secrets masked](https://raw.githubusercontent.com/iramarfalcao/hyperenv/main/docs/store/vscode-1-profiles.png)

![web-staging applied, with the reload command](https://raw.githubusercontent.com/iramarfalcao/hyperenv/main/docs/store/vscode-2-applied.png)

![Dark theme, secrets revealed](https://raw.githubusercontent.com/iramarfalcao/hyperenv/main/docs/store/vscode-3-dark-revealed.png)

A **HyperEnv** view in the activity bar lists your profiles. Each one expands to
its variables; secrets are masked until you reveal them, and switched-off
variables say so. From the view you can:

- **Profiles** — create, rename, duplicate and delete (the applied profile
  cannot be deleted; Undo it first). Deleting asks first.
- **Variables** — add (`NAME=value`), edit the value (click the variable),
  delete, switch on/off, mark or unmark as secret, copy the value.
- **Apply** a profile and **Undo**. HyperEnv changes only *new* terminals, so
  after either one the extension offers to run the reload command in the active
  terminal, or to copy it.
- **Import** a `.env` file into a profile and **export** a profile as `.env`.

The status bar shows what is applied (or that nothing is) and how many drift
items `hyperenv status` reports. When you edit the applied profile after
applying it, the tree marks it **changed since applied**: apply it again to
update new terminals. The view refreshes when the window regains focus, so
changes made in the desktop app or a terminal show up.

The extension carries no engine of its own. It drives HyperEnv's `hyperenv`
command, which uses the same store, journal and startup file as the desktop
apps — whichever one you click, it is the same state. Works on macOS, Linux and
Windows.

## Installing the command

The extension needs `hyperenv` **2.0 or later** (it checks `hyperenv --json
version` and says so if the one it finds is older). The desktop app ships it; on
its own:

```sh
curl -fsSL https://hyperenv.falcaosl.com/install-cli.sh | sh   # macOS / Linux
irm https://hyperenv.falcaosl.com/install.ps1 | iex            # Windows (PowerShell)
```

## Finding the command

In order:

1. the `hyperenv.cliPath` setting;
2. macOS: `/Applications/HyperEnv.app/Contents/Helpers/hyperenv`, then the same
   under `~/Applications`;
3. `hyperenv` on your `PATH`;
4. where the install scripts put it: `~/.local/bin/hyperenv` (macOS/Linux),
   `%LOCALAPPDATA%\Programs\hyperenv\hyperenv.exe` (Windows);
5. the copy bundled with the extension (`bin/hyperenv`, `bin\hyperenv.exe` on
   Windows) in the platform-specific packages. With it, nothing needs
   installing; anything you install yourself takes precedence.

The command's grammar and JSON shapes are in `crates/cli/README.md` at the
repository root.

## Building

```sh
npm ci
npm test          # compiles, then runs the tests with plain Node
npm run package   # -> hyperenv-<version>.vsix
```

The unit tests parse real output of the command (`src/test/fixtures`, captured
from `hyperenv --home <temp dir> --json …`), and cover the lookup order on each
platform, the version check, how each call is built, `NAME=value` parsing and
the "changed since applied" rule. An integration test runs the real command
against a throwaway home (never yours) — create, set, list, apply, status,
undo, import, export — when `HYPERENV_CLI` points at a binary:

```sh
cargo build --release -p hyperenv-cli
HYPERENV_CLI=../../target/release/hyperenv npm test
```

Without it, that test is skipped. The view itself is exercised by pressing F5
in VS Code (Run Extension).

The icons in `media/` are HyperEnv's own (`design/icons`), in a light and a
dark copy because VS Code tree icons do not follow `currentColor`.
