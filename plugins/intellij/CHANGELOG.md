<!-- Keep a Changelog guide -> https://keepachangelog.com -->

# HyperEnv for IntelliJ Changelog

## [Unreleased]

## [2.1.0]

First version on the Visual Studio Marketplace. Plugin versions are now plain X.Y.Z in every store: an odd minor (2.1.x) is a pre-release, an even one (2.2.0) stable. Same content as 2.0.0-alpha.3.

## [2.0.0-alpha.3]

- The plugin carries the `hyperenv` command for macOS, Linux and Windows
  (`bin/`), used as the last resort when none is installed: no install step needed.
- Plugin icon (the HyperEnv app icon).
- The product is named HyperEnv throughout.

## [2.0.0-alpha.2]

First release through the store pipeline (Open VSX and the JetBrains Marketplace). No functional change from 2.0.0-alpha.1.

## [2.0.0-alpha.1]

Rebuilt for the new `hyperenv` command. Needs `hyperenv` 2.0 or later.

### Added

- A flat list of profiles, the applied one marked, with the selected profile's
  variables below: secrets masked with a reveal toggle, disabled ones dimmed.
- Rename profiles; mark/unmark a variable secret; copy a value.
- Import a `.env` file into a profile and export a profile as `.env`.
- Status line: what is applied (or the original environment), *changed since
  applied*, and drift reported by `hyperenv status`.
- Undo shows the command for a terminal that is already open, as Apply does.
- Finds the command on macOS, Linux and Windows: the HyperEnv app, `PATH`,
  then the installers' locations; explains how to install it when missing and
  refuses a 1.x command.
- HyperEnv's own interface icons, in light and dark variants.

### Changed

- Every call runs on one background queue, in order, never on the UI thread.
- Duplicate asks for the new profile's name.

### Removed

- Projects, profile kinds (dev/hml/prd/custom), the Default profile and
  variable notes — HyperEnv has none of them.
- *Install Hook*: `hyperenv apply` installs it when needed.

## [0.1.0]

### Added

- Tool window with projects, profiles and variables, read from the `hyperenv`
  1.x command that shipped inside the HyperEnv app.
- Create and delete projects and profiles; duplicate a profile.
- Add, edit, switch on/off and delete variables; secrets hidden in the list.
- Apply and Revert, with the reload command one click away.
- Install the shell hook from the IDE.
- Settings › Tools › HyperEnv: where the command is.
