# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than in a public issue.

Use GitHub's [private vulnerability reporting](https://github.com/iramarfalcao/hyperenv/security/advisories/new)
for this repository. You should get an acknowledgement within a few days.

## Supported versions

The most recent release is supported. Fixes are shipped as a new patch release.

## What this app can and cannot protect

HyperEnv is worth being precise about, because it handles credentials.

**Values applied to your shell are stored in plaintext.**
`~/.config/hyperenv/session.zsh` must be sourceable by `zsh`, so it necessarily
contains readable values. The file is written `0600` in your home directory.
Marking a variable as secret hides it in the interface — that is presentation
only, and it is documented as such in the code. Treat the file exactly as you
would treat a `.env`: do not commit it, do not sync it to a shared drive.

**The app is not sandboxed.** It cannot be: managing `~/.zprofile` and running
your login shell to observe its environment are both outside what the App
Sandbox permits. It runs with the hardened runtime enabled.

**Public builds are ad-hoc signed, not notarized.** Verify the SHA-256 published
with every release before opening a disk image, or build from source.

**Subprocess execution is bounded.** The environment probe runs your login shell
with a timeout and a sentinel, and refuses to follow symlinks that leave your
home directory.

## Recovering from a bad state

If HyperEnv has left your shell unusable, this bypasses everything it generates
without needing the app:

```sh
HYPERENV_DISABLE=1 zsh -l
```

From there, remove the marker block from `~/.zprofile`, or restore the backup
taken before the first edit from `~/.config/hyperenv/backups/`.
