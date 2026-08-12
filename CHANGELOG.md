# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org).

## [1.0.1] — 2026-08-12

### Fixed

- **The window rendered with every column's content pushed off screen.**
  `.fixedSize(horizontal: false, vertical: true)` on the snapshot notice's long
  line asked for the text's ideal height, and during the split view's measuring
  pass the proposed width is nearly zero — so it wrapped into a column around
  2000pt tall and dragged the whole layout with it, columns running far past the
  bottom edge. The notice only renders for the Default profile, which is the
  first project and the one the selection falls back to at launch, so the app
  appeared to open empty and to lose its data whenever Default was selected.
- **One long value pushed the columns sideways.** A plain `TextField` reports an
  ideal width that fits its entire value, and the snapshot holds a 412-character
  `PATH`. That row asked for 3417pt inside a column a fifth as wide.
- **Exporting the snapshot wrote a file with no variables in it.** Every variable
  in it is switched off — correctly, since a search path must never be replayed
  into a shell — and the exporter only ever wrote the switched-on ones. Export
  now takes a scope, and an export that would carry nothing says so instead of
  writing an empty file.
- Selecting a profile carried the previous one's filter text and revealed
  secrets, because SwiftUI reused a single editor across profiles.
- The selection could name a profile from the previous project, so the editor
  showed one profile while no card looked selected.
- Deleting a project left the selection pointing into the subtree being deleted.

### Changed

- Creating a project asks for a name instead of making one called "New Project",
  and no longer invents three profiles for it.
- Creating a profile asks for a name and a badge, in a sheet like the project
  one. The same sheet edits an existing profile.
- The window opens at HD, centred, and shrinks to fit the screen it opens on.
- Liquid Glass now covers the status bar and both notices, grouped in one
  container so a banner blends into the bar rather than stacking on it.
- The icon's palette drives the interface: the environment tints and the accent
  colour are generated from the constants the icon is drawn with. Development
  moves from mint to green. The one-time setup notice is no longer orange, which
  read as a warning and collided with the homologation tint.
- Sound for four events — applied, reverted, copied, failed — honouring macOS's
  own interface-sound preference and a toggle in the Environment menu.
- Installable with Homebrew: the repository doubles as a tap.

### Infrastructure

- `Tests/run-layout-checks.sh` and `Tests/run-export-checks.sh`, both verified by
  reintroducing the bug they guard and watching them fail.
- `Scripts/capture-window.sh` renders the real window offscreen and reports what
  AppKit actually built.
- The release workflow signs with a secure timestamp, notarizes and staples the
  app *before* building the disk image, then notarizes and staples the image and
  re-checksums it.

## [1.0.0] — 2026-08-12

First public release.

### Added

- **Projects and profiles.** A project per codebase or client, holding `dev`,
  `hml`, `prd` and custom profiles. Each profile is a list of environment
  variables that can be enabled individually.
- **Apply and revert.** Applying writes a generated `session.zsh` that new login
  shells source. Reverting restores every variable's previous value — unsetting
  only the ones that did not exist before.
- **A guarded block in `~/.zprofile`.** Three lines, inserted once, between
  markers. The file is backed up before the first edit and can be restored byte
  for byte, including CRLF endings and a missing trailing newline.
- **`HYPERENV_DISABLE`.** A kill switch that makes every generated script a
  no-op, so a shell can always be started as if the app were not installed.
- **Reload command for open terminals.** Applying cannot reach shells that are
  already running, so the command that can is one click from the status bar.
- **Drift detection**, structural and semantic — including the case a checksum
  cannot see, where something assigns the same variable after the managed block
  and quietly wins.
- **First-launch snapshot** of the existing shell environment into a read-only
  `Default` profile, bucketed by why each variable was or was not considered safe
  to reuse.
- **`.env` import and export** in three dialects — POSIX shell, quoted dotenv and
  `docker --env-file` — with a preview before anything is written.
- **Menu bar item** for switching profiles without bringing the window forward,
  carrying the active environment as a shape that survives monochrome rendering.
- **Confirmation before applying production**, the one action that can cause real
  damage.
- **Store recovery.** A SwiftData store this build cannot open is moved aside
  rather than deleted, so the app still launches and can explain itself.

### Infrastructure

- Universal (`arm64` + `x86_64`) builds, ad-hoc signed with the hardened runtime,
  packaged as a disk image and published with a SHA-256 on every tag.
- CI on every push and pull request: 121 pure-logic checks, a real-`zsh`
  integration suite in an isolated `ZDOTDIR`, and the full build-and-package path.
- Optional, secret-driven Developer ID signing and notarization.

[1.0.1]: https://github.com/iramarfalcao/hyperenv/releases/tag/v1.0.1
[1.0.0]: https://github.com/iramarfalcao/hyperenv/releases/tag/v1.0.0
