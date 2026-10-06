# Architecture — HyperEnv

One Rust core, three windows, one command. Everything that decides what
happens to the user's environment lives in `crates/`, once; every surface on
top of it is thin.

```
crates/core      pure logic — no I/O            ← every dangerous transform lives here
crates/engine    what touches the machine       ← startup files, journal, registry, shell probe
crates/cli       the `hyperenv` command          ← also a library: the shared command contract
crates/ffi       C interface for the macOS app   ← one call: the command's grammar in, JSON out
apps/macos       SwiftUI app                     ← links crates/ffi
apps/desktop     Slint app (Windows, Linux)      ← links crates/engine directly
design/          tokens.json + icons/            ← generated into Swift and Slint, never copied by hand
```

## Core — pure, and therefore testable

`crates/core` performs no I/O. Every function is a value-in, value-out
transform, so the riskiest operation in the product — rewriting a shell
startup file — is reachable from a unit test with a fixture string.

| Module | Responsibility |
|---|---|
| `types` | `EnvKey` (validated, ASCII), `EnvValue`, `EnvSet` (sorted), `PriorState` (absent ≠ empty). |
| `guarded_block` | Idempotent insertion and removal of the marker-delimited block. Round-trips CRLF and a missing trailing newline; refuses malformed markers rather than guessing. Markers are the 1.x ones, so a 1.x block is recognised. |
| `render` | The session script and its inverse for zsh, bash, fish and PowerShell; the hook line for each. |
| `quoting` | Single-quoting per dialect — POSIX, fish, PowerShell — and dotenv double quotes. |
| `dotenv` | `.env` parsing and emission in three dialects (POSIX shell, dotenv, docker), with per-line diagnostics. |
| `reconcile` | The apply/un-apply plan. **A key's original value is captured once**, on the unmanaged-to-managed transition, and only released on the way back; re-measuring would record our own value as the user's. Also semantic drift. |
| `probe` | Parses the NUL-separated `env -0` that follows a sentinel. |
| `seed` | Buckets an observed environment (user, session, path-like, cosmetic, rejected…) for macOS, Linux and Windows. |

## Engine — the part that touches the machine

| Module | Responsibility |
|---|---|
| `layout` | Every path, injectable: home from the password database, the startup file per shell (`~/.zprofile` or `$ZDOTDIR/.zprofile`; `~/.bash_profile` on macOS and `~/.bashrc` on Linux; `config.fish`), config in `~/.config/hyperenv` or `%APPDATA%\hyperenv`. `HYPERENV_HOME` redirects all of it for development — and then ignores the caller's `ZDOTDIR` and `APPDATA`. |
| `store` | The profiles: a flat list in `profiles.json` (0600). |
| `journal` | What is applied right now, as plain JSON — written as *pending* before anything is touched, committed after. Reads the 1.x journal too. |
| `engine` | Apply, un-apply, hook, drift, recovery, under a cross-process lock. The startup file is read and the change computed **before** any write, so an unreadable or malformed file stops everything. |
| `probe` | Runs the login shell — the way a terminal opens it — with `HYPERENV_DISABLE=1` to observe the environment as if HyperEnv were not installed. |
| `registry` | Windows: `HKCU\Environment`, keeping each value's original type (`REG_SZ` or `REG_EXPAND_SZ`), then `WM_SETTINGCHANGE`. Behind a trait so the logic is tested everywhere with an in-memory registry. |
| `migrate` | macOS: reads the 1.x SwiftData store (never writes it) into flat profiles. |

### Two sources of truth, deliberately

`profiles.json` holds **desired** state — what you have configured. The
journal holds **applied** state — what is on the machine. If the profiles are
lost or corrupted, the journal and the generated scripts (including the
inverse, written at apply time) still describe how to put everything back.

## Surfaces

**The command** (`crates/cli`) is also a library: `execute(args) -> Output`.
Its `--json` envelope (`{ok, data}` / `{ok, error}`) is the contract for the
editor plugins *and* the macOS app. See `crates/cli/README.md`.

**macOS** (`apps/macos`) links `crates/ffi`, which exposes one function,
`hyperenv_run(argv_json) -> envelope_json`. The window sends the command's
grammar and decodes the same JSON the plugins read — so the Mac app needs no
logic of its own and inherits the command's tests. Calls that start the
user's shell (apply, undo, drift) run off the main actor. Xcode builds the
Rust library as a build phase (`Scripts/build-core.sh`); the universal
`hyperenv` command ships at `Contents/Helpers/hyperenv`.

**Windows and Linux** (`apps/desktop`) link `crates/engine` directly and draw
with Slint. Engine calls that start the shell run on a worker thread.

## Design

`design/tokens.json` and `design/icons/` are the only source of the visual
language. `apps/desktop/build.rs` generates the Slint tokens at build time;
`apps/macos/Scripts/generate-design.sh` writes `Tokens.swift` and the icon
assets (run it after changing `design/`). Both apps embed Schibsted Grotesk
and JetBrains Mono (OFL) and use no system icons.

## Testing

`cargo test --workspace` — run on macOS, Linux and Windows in CI:

- **core** — the 1.x Swift Core's checks, ported, plus every shell dialect;
  hostile values sourced in real zsh, bash, fish and PowerShell and compared
  byte for byte.
- **engine** — against a throwaway home: apply, undo, backups, symlinked
  dotfiles, malformed blocks, the lock, drift, crash recovery, the in-memory
  registry, the 1.x journal and a SwiftData fixture.
- **end to end** — a real login shell: apply, open a new terminal, see the
  profile; undo, see the original.
- **command** — the whole grammar against a throwaway home.
- **ffi** — the C boundary, including malformed input.
