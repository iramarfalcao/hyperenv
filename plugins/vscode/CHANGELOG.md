# Changelog

## [2.0.0-alpha.2]

First release through the store pipeline (Open VSX and the JetBrains Marketplace). No functional change from 2.0.0-alpha.1.

## [2.0.0-alpha.1]

Rebuilt for HyperEnv 2's `hyperenv` command. Requires `hyperenv` 2.0 or later;
the 1.x command is no longer supported.

### Changed

- A flat list of profiles replaces projects → profiles; risk kinds
  (dev/hml/prd) and the Default profile are gone, as in HyperEnv 2.
- Revert is now **Undo**: each variable goes back to its previous value.
- The command is looked for in the setting, the macOS app, `PATH`, then the
  installers' places (`~/.local/bin`, `%LOCALAPPDATA%\Programs\hyperenv`);
  when it is missing the extension shows the install commands. Works on macOS,
  Linux and Windows.
- HyperEnv 2's own icons throughout, including the activity bar.

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
