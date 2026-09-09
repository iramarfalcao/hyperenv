# HyperEnv for VS Code

Switch the environment variables your terminals inherit — per project, per
environment — from inside VS Code.

An **Environments** view lists your HyperEnv projects, their profiles (dev,
hml, prd, custom) and every variable. Create a project, add a profile, add or
edit variables, and press **Apply**: new terminals, including VS Code's own,
inherit that environment. **Revert** puts your original values back. The
status bar shows what is applied; clicking it copies the reload command for a
terminal that is already open.

The extension does not carry an engine of its own. It drives the `hyperenv`
command that ships inside the HyperEnv app, so the app, the IntelliJ plugin
and this extension share one store, one journal and one writer to
`~/.zprofile`. **Requires macOS and the HyperEnv app.**

## Finding the command

In order: `hyperenv.cliPath` in your settings, then `hyperenv` on your `PATH`,
then `/Applications/HyperEnv.app/Contents/Helpers/hyperenv` and the same under
`~/Applications`. The command's grammar and JSON shapes are in `docs/CLI.md`
at the repository root.

## Building

```sh
npm install
npm test          # compiles, then runs the unit tests with plain Node
npm run package   # -> hyperenv-<version>.vsix
```

The unit tests cover the command's JSON envelope, the lookup order, how the
client builds each call, and the variable-name rule — everything that can be
proven without an editor. The view and its commands are exercised by pressing
F5 in VS Code (Run Extension).
