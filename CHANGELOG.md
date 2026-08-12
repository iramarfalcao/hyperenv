# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org).

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

[1.0.0]: https://github.com/iramarfalcao/hyperenv/releases/tag/v1.0.0
