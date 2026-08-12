# Architecture

HyperEnv is a SwiftUI app for macOS 26, written in Swift 6 with strict
concurrency. It is organised in four layers, and the boundary between the first
two is the one that carries the design.

```
hyperenv/
├── Core/       pure logic, no I/O          ← every dangerous transform lives here
├── Engine/     the filesystem and the shell
├── Models/     SwiftData persistence
├── Views/      SwiftUI
└── Design/     the visual language
```

## Core — pure, and therefore testable

`Core/` performs no I/O at all. Every type in it is a `String → String` or
`Value → Value` transform, which means the riskiest operation in the app —
rewriting `~/.zprofile` — is reachable from a unit test with a fixture string,
with no filesystem, no app bundle and no test host.

| File | Responsibility |
|---|---|
| `GuardedBlock.swift` | Idempotent insertion and removal of the marker-delimited block. Round-trips CRLF and a missing trailing newline so dotfile repos see no spurious diffs. |
| `SessionScriptRenderer.swift` | Renders `session.zsh`, its inverse `unsession.zsh`, and the three-line hook body. |
| `ShellQuoting.swift` | Single-quoting that survives values containing quotes, `$` and `#`. |
| `DotenvCodec.swift` | `.env` parsing and emission in three dialects. |
| `EnvTypes.swift` | `EnvKey`, `EnvValue`, `EnvSet`, `PriorState` — the vocabulary. |
| `SeedFilter.swift` | Buckets an observed environment into what is safe to reuse. |
| `Reconciler.swift` | Diffs desired state against observed state to produce a plan. |
| `EnvOutputParser.swift` | Parses the probe's null-delimited output. |

`Tests/CoreChecks/` compiles this directory with `swiftc` and runs 121 assertions
against it. It needs nothing but a Swift toolchain.

## Engine — the part that touches the machine

`Engine/` is where I/O happens, behind an actor.

| File | Responsibility |
|---|---|
| `ApplyEngine.swift` | The actor that owns apply / unapply / hook installation, under a lock file. |
| `FileSystemGateway.swift` | Atomic writes, backups, symlink-escape refusal. |
| `EnvironmentProbe.swift` | Runs the login shell with `HYPERENV_DISABLE=1` to observe the environment *as if HyperEnv were not installed*. |
| `JournalStore.swift` | The on-disk record of what is currently applied. |
| `SeedService.swift` | First-launch snapshot into the `Default` profile. |
| `ProcessRunner.swift` | Bounded subprocess execution with a timeout. |
| `Paths.swift` | Every path the app knows, resolved from the password database rather than `NSHomeDirectory()`. |

### Two sources of truth, deliberately

SwiftData holds **desired** state: projects, profiles, variables — what you have
configured.

A JSON journal at `~/.config/hyperenv/journal/current.json` holds **applied**
state: what is actually on the machine right now.

They are separate on purpose. If the SwiftData store is corrupted, or a schema
migration fails, or the app is deleted, the journal and the generated scripts are
still on disk and still describe how to put everything back. A design where the
database is the only record of what was mutated can strand a user with modified
dotfiles and no way to reverse them.

The app also recovers from a store it cannot open: the file is *moved aside*
rather than deleted, and the app still launches so it can say what happened.

### Actor isolation

`@Model` types are not `Sendable` and are bound to the `ModelContext` that made
them, so they never cross an actor boundary. `SnapshotMapper` copies everything
the engine needs into a plain `ProfileSnapshot` value first.

## Drift detection

Two kinds of drift are checked, because a checksum only catches one of them.

**Structural** — the managed file was edited by hand, the block was removed from
`~/.zprofile`, or the login session restarted. These are checksum and
existence questions.

**Semantic** — the block is intact, the file is untouched, and the environment
*still* does not match, because something assigned the same variable after our
block and quietly won. This is caught by re-probing the shell and comparing
values, and it is the failure users otherwise spend an afternoon on.

## Views

`ContentView` is a three-column `NavigationSplitView` — projects, profiles,
variables — with the notices and the status bar as **siblings** of the split
view, not overlays on it. An element floating over the columns covers the bottom
row of all three at once, which is exactly where the data being read lives.

`Design/ProfileStyle.swift` holds the visual language. Colour there is doing real
work rather than decoration: the question the app exists to answer is "which
environment am I about to point my tools at". Because colour alone fails for
roughly one man in twelve, the environment class is always stated redundantly —
symbol, colour and text — and in the menu bar, where icons are rendered as
monochrome templates, production is carried by a *shape* no other state uses.

## The icon

`Scripts/generate-app-icon.swift` renders the mark once and writes it to all
three places it is needed — the asset catalog, `assets/HyperEnv.icns` for the
disk image's volume icon, and `assets/icon-1024.png` for the documentation. The
three dots in it are the literal `dev` / `hml` / `prd` tints, so the icon cannot
drift away from the palette the app actually uses.

## Testing

| Suite | What it proves |
|---|---|
| `Tests/run-core-checks.sh` | The generated strings, parsing and quoting are correct. Pure, fast, no I/O. |
| `Tests/run-shell-integration.sh` | A real `zsh`, in an isolated `ZDOTDIR`, produces the promised environment — and un-applying restores the previous values. Refuses to run anywhere near the real `$HOME`. |

The second suite is the one that matters. Unit tests prove the strings are built
correctly; only a real shell proves the contract.
