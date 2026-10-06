# Changelog

## [Unreleased]

## [2.1.3]

Published by Iramar Falcao in every store.

## [2.1.0]

First version on the Visual Studio Marketplace. Plugin versions are now plain X.Y.Z in every store: an odd minor (2.1.x) is a pre-release, an even one (2.2.0) stable. Same content as 2.0.0-alpha.3.

## [2.0.0-alpha.3]

- Platform-specific packages bundle the `hyperenv` command (`bin/`), used as
  the last resort when none is installed: no install step needed.
- Marketplace icon and banner.
- The product is named HyperEnv throughout.

## [2.0.0-alpha.2]

First release through the store pipeline (Open VSX and the JetBrains Marketplace). No functional change from 2.0.0-alpha.1.

## [2.0.0-alpha.1]

Rebuilt for HyperEnv's `hyperenv` command. Requires `hyperenv` 2.0 or later;
the 1.x command is no longer supported.

### Changed

- A flat list of profiles replaces projects → profiles; risk kinds
  (dev/hml/prd) and the Default profile are gone, as in the 2.0 command.
- Revert is now **Undo**: each variable goes back to its previous value.
- The command is looked for in the setting, the macOS app, `PATH`, then the
  installers' places (`~/.local/bin`, `%LOCALAPPDATA%\Programs\hyperenv`);
  when it is missing the extension shows the install commands. Works on macOS,
  Linux and Windows.
- HyperEnv's own icons throughout, including the activity bar.

### Added

- Rename profiles; duplicate under a name of your choice.
- Mark or unmark a variable as secret; reveal secrets one at a time or all at
  once; copy a value.
- Import a `.env` into a profile and export a profile as `.env`.
- After Apply or Undo, run the reload command in the active terminal or copy it.
- Status bar shows the drift count; the tree marks the applied profile as
  "changed since applied" when its variables were edited after applying.
- Refresh when the window regains focus.

### Removed

- Projects, profile kinds, the Default profile, notes and the Install Shell
  Hook command (applying installs the hook).

## 0.1.0 (never released)

- First version, for the HyperEnv 1.x command (macOS only).
