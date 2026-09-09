# plugins/

Editor integrations. Each subfolder is an independent plugin with its own
build and its own version; what they share is the repository, the licence,
and — the part that matters — **the engine**.

| Folder | Target | Build |
|---|---|---|
| `intellij/` | IntelliJ family — IDEA, PyCharm, WebStorm, GoLand, RustRover, CLion | Gradle, Kotlin |
| `vscode/` | Visual Studio Code | npm, TypeScript |

## One engine

Neither plugin carries an engine. Both drive the `hyperenv` command that
ships inside `HyperEnv.app` (`Contents/Helpers/hyperenv`), which opens the
same SwiftData store and the same journal the app does. So the app, the
IntelliJ plugin and the VS Code extension are three windows onto one state,
with one writer to `~/.zprofile` — and everything the engine suite proves
(journal before dotfile, baseline captured once, backup once, lock) holds
whichever surface pressed Apply. The command's grammar and JSON shapes are in
[`docs/CLI.md`](../docs/CLI.md).

The consequence is honest and worth stating: **the plugins need the HyperEnv
app installed, and are macOS-only** — as the product is.

## What each one does

The same five things the app does: create a project, create a profile
(dev, hml, prd, custom), create and edit variables (with secret and on/off),
apply, revert. Plus duplicate a profile (how the machine snapshot becomes
something you can apply), install the shell hook, and copy the reload command
for a terminal that is already open.

| | IntelliJ | VS Code |
|---|---|---|
| Surface | Tool window, right side | Activity-bar view "HyperEnv" |
| Applied indicator | Bold row with ● in the tree | Status bar item |
| Command location | Settings › Tools › HyperEnv | `hyperenv.cliPath` |
| Unit tests | JUnit: envelope, lookup order, name rule | `node --test`: same, plus how each call is built |
| Editor-in-the-loop | `./gradlew runIde` | F5 (Run Extension) |

Both look for the command in the same order: the setting, then `PATH`, then
`/Applications/HyperEnv.app/Contents/Helpers/hyperenv`, then the same under
`~/Applications`.

## Building

```sh
cd plugins/intellij && ./gradlew build verifyPlugin     # unit tests + IDE compatibility
cd plugins/vscode   && npm install && npm test && npm run package
```

## CI

`.github/workflows/plugin-build.yml` runs both when anything under
`plugins/**` changes: Gradle build + `verifyPlugin` for IntelliJ, `npm test` +
`vsce package` for VS Code. The app's own workflow ignores `plugins/**`, so
neither side can break the other's release.

The JetBrains template's `release.yml` is kept in `intellij/.github/workflows/`
as reference and is inert: it fires on any GitHub release, and here releases
belong to the macOS app. When the plugin has something to publish it gets a
gate of its own.
