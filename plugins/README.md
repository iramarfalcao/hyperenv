# plugins/

Editor integrations for HyperEnv 2. Each subfolder is an independent plugin
with its own build; they share a version, the licence, and — the part that
matters — **the engine**.

| Folder | Target | Store | Build |
|---|---|---|---|
| `intellij/` | IntelliJ family — IDEA, PyCharm, WebStorm, GoLand, RustRover, CLion | JetBrains Marketplace | Gradle, Kotlin |
| `vscode/` | VS Code, plus Cursor, VSCodium, Windsurf (Open VSX) | Visual Studio Marketplace, Open VSX | npm, TypeScript |

## One engine

Neither plugin carries an engine. Both drive the `hyperenv` command, whose
grammar and `--json` shapes are in
[`crates/cli/README.md`](../crates/cli/README.md) — the same contract the macOS
app uses. So the apps and both plugins are windows onto one state, with one
writer to the shell's startup file (or, on Windows, the registry), and every
guarantee the core's tests prove holds whichever surface pressed Apply.

They run on macOS, Linux and Windows, and look for the command in the same
order: the plugin's setting; on macOS the copy inside `HyperEnv.app`
(`/Applications`, then `~/Applications`); `PATH`; then where the installers
put it — `~/.local/bin/hyperenv`, or `%LOCALAPPDATA%\Programs\hyperenv\hyperenv.exe`.
With none found they show the install commands from the site; a command older
than 2.0 is refused with an update message.

## What each one does

The same as the desktop apps, over a flat list of profiles:

- **Profiles** — create, rename, duplicate, delete (with confirmation; never
  the applied one).
- **Variables** — add (`NAME=value`), edit, delete, turn on or off, mark as
  secret (masked until revealed), copy.
- **Apply and Undo** — then the reload command for terminals already open,
  since HyperEnv changes what *new* terminals get.
- **Status** — what is applied, drift, and *changed since applied*.
- **`.env`** — import into a profile, export from one.

| | IntelliJ | VS Code |
|---|---|---|
| Surface | Tool window: status line, profile list, variables table | Activity-bar view: profiles that expand to their variables |
| Applied indicator | Bold row with ● applied, plus the status line | Tree marker, plus a status bar item with drift |
| After Apply | Balloon with the reload command and a copy button | Offer to run it in the active terminal, or copy it |
| Command location | Settings › Tools › HyperEnv | `hyperenv.cliPath` |
| Tests | JUnit: envelope against real output, lookup order, name rule, *changed since applied*, end-to-end on a temp `--home` | `node --test`: the same, plus how each call is built |
| Editor-in-the-loop | `./gradlew runIde` | F5 (Run Extension) |

Icons are HyperEnv 2's own (`design/icons`), recoloured for each editor's
light and dark themes; where the set has no match (refresh, edit, settings)
the editor's own icon is used rather than inventing one.

## Building

```sh
cargo build --release -p hyperenv-cli                    # the command the end-to-end tests drive
cd plugins/intellij && HYPERENV_CLI=../../target/release/hyperenv ./gradlew build verifyPlugin
cd plugins/vscode   && npm ci && npm run compile && HYPERENV_CLI=../../target/release/hyperenv npm test
```

Without `HYPERENV_CLI` (or the built binary) the end-to-end tests are skipped
and the rest still runs. They only ever use a throwaway `--home`.

## CI and stores

- `.github/workflows/plugin-build.yml` builds and tests both when anything
  under `plugins/**` changes. The app's workflow ignores `plugins/**`, so
  neither side can break the other's release.
- `.github/workflows/plugins-release.yml` publishes on a `plugins-v*` tag: it
  checks the tag against both manifests, builds and tests against the real
  command, publishes to the Visual Studio Marketplace, Open VSX and the
  JetBrains Marketplace (signed), and attaches the `.vsix` and `.zip` to a
  GitHub release that never becomes "latest". A pre-release version
  (`2.0.0-alpha.1`) goes to each store's pre-release channel. A store whose
  secret is missing is skipped.

To release: bump `plugins/vscode/package.json` and
`plugins/intellij/gradle.properties` to the same version, then
`git tag plugins-v<version> && git push origin plugins-v<version>`.

The JetBrains template's `release.yml` in `intellij/.github/workflows/` is
inert reference; `plugins-release.yml` is the one that publishes.
