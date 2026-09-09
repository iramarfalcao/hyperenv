# HyperEnv for IntelliJ

<!-- Plugin description -->
Switch the environment variables your terminals inherit — per project, per
environment — from inside the IDE.

A tool window lists your HyperEnv projects, their profiles (dev, hml, prd,
custom) and every variable. Create a project, add a profile, add or edit
variables, and press **Apply**: new terminals, including the IDE's own, inherit
that environment. **Revert** puts your original values back.

The plugin does not carry an engine of its own. It drives the `hyperenv`
command that ships inside the HyperEnv app, so the app, the IntelliJ plugin and
the VS Code extension share one store, one journal and one writer to
`~/.zprofile`. Requires macOS and the HyperEnv app.
<!-- Plugin description end -->

## Building

```sh
./gradlew build            # compiles, runs the unit tests
./gradlew verifyPlugin     # compatibility against the declared IDE range
./gradlew runIde           # a sandbox IDE with the plugin loaded
```

The unit tests cover the command's JSON envelope, the lookup order for the
command, and the variable-name rule — everything that can be proven without an
IDE. The tree and dialogs are exercised with `runIde`.

## Finding the command

In order: the path in *Settings › Tools › HyperEnv*, then `hyperenv` on your
`PATH`, then `/Applications/HyperEnv.app/Contents/Helpers/hyperenv` and the
same under `~/Applications`. See `docs/CLI.md` in the repository root for the
command's grammar and JSON shapes.
