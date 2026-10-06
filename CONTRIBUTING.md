# Contributing

Thanks for taking a look. Issues and pull requests are welcome.

## Getting set up

```sh
git clone https://github.com/iramarfalcao/hyperenv.git
cd hyperenv
open apps/macos/hyperenv.xcodeproj
```

You need Xcode 26.5 or later. There are no package dependencies.

## Before you open a pull request

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace -- --test-threads=1
```

All three must pass. CI runs them on macOS, Linux and Windows, plus a full
universal macOS build and disk image, and the release packages for Windows and
Linux, so a packaging break shows up on the pull request rather than at tag
time.

## Where code goes

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The boundary that matters:

- **`crates/core`** performs **no I/O**. If your change can be expressed as a
  transform over values, it belongs here, with a test. This is what keeps the
  code that rewrites a shell startup file fully testable.
- **`crates/engine`** touches the disk, the shell and the registry. Read and
  validate before you write, and keep the journal ahead of the change.
- **The apps** (`apps/macos`, `apps/desktop`) hold no environment logic. A
  feature the window needs is a command first (`crates/cli`), so the plugins
  get it too.
- **Design** changes go in `design/`; regenerate rather than edit
  `Tokens.swift` or the Slint tokens by hand.

## Changes that touch the user's dotfiles

Anything that writes to `~/.zprofile`, `session.zsh` or `unsession.zsh` needs:

1. a Core-level test with a fixture string, including the awkward cases — CRLF
   line endings, a missing trailing newline, values containing quotes, `$` and
   `#`;
2. a shell-integration assertion proving the round trip in a real `zsh`;
3. a demonstration that removing the block restores the file **byte for byte**.

This is not ceremony. The file in question starts the user's login shell, and
getting it wrong locks someone out of their terminal.

## Style

Match the surrounding code. Comments in this codebase explain *why* a decision
was made — particularly where the obvious approach is wrong — rather than
restating what the line does. If you had to work something out, that is worth a
comment; if you did not, it probably is not.

## Reporting a problem

Please include your macOS version, whether the hook was installed, and — if it is
safe to share — the contents of `~/.config/hyperenv/session.zsh`. If HyperEnv has
made your shell unusable, this gets you back immediately:

```sh
HYPERENV_DISABLE=1 zsh -l
```

Then remove the block from `~/.zprofile`, or restore the backup from
`~/.config/hyperenv/backups/`.

## Security

Do not open a public issue for a security problem. Email the maintainer instead;
see [SECURITY.md](SECURITY.md).
