# Releasing

## Cutting a release

Tag and push. That is the whole process.

```sh
git tag v1.0.1
git push origin v1.0.1
```

The [release workflow](../.github/workflows/release.yml) then:

1. runs `Tests/run-core-checks.sh` and `Tests/run-shell-integration.sh` — a
   broken shell contract cannot ship;
2. builds a universal (`arm64` + `x86_64`) Release archive with the tag's version
   stamped into `MARKETING_VERSION`;
3. signs it — ad-hoc by default, Developer ID if the secrets below are set;
4. packages `HyperEnv-<version>.dmg` with a `/Applications` symlink and a
   first-launch note;
5. publishes a GitHub Release with the disk image, its SHA-256, and notes that
   state the architectures and signature **read back off the artifact** rather
   than assumed.

You can also run it by hand from the Actions tab with a version input; it creates
the tag if it does not exist yet.

## Building locally

```sh
Scripts/build-release.sh 1.0.1                       # -> build/export/HyperEnv.app
Scripts/make-dmg.sh build/export/HyperEnv.app 1.0.1  # -> build/HyperEnv-1.0.1.dmg
```

`SIGN_IDENTITY` selects the codesigning identity and defaults to `-` (ad-hoc).

## Signing and notarization

The default public build is **ad-hoc signed**. That is what a repository with no
paid Apple Developer account can honestly produce, and it is better than
unsigned: an unsigned binary will not launch on Apple silicon at all.

The cost is that Gatekeeper blocks the first launch, and every user has to
right-click → Open or strip the quarantine attribute.

To ship builds that open normally, add these repository secrets. Each optional
step turns itself on when its secret is present, and nothing else changes.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Base64 of a "Developer ID Application" `.p12` export |
| `MACOS_CERTIFICATE_PASSWORD` | The password used on that export |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_TEAM_ID` | Your 10-character Apple team identifier |
| `MACOS_NOTARY_APPLE_ID` | The Apple ID used for notarization |
| `MACOS_NOTARY_PASSWORD` | An app-specific password for that Apple ID |

Producing the certificate secret:

```sh
# Export "Developer ID Application" from Keychain Access as certificate.p12 first
base64 -i certificate.p12 | pbcopy
```

With `MACOS_CERTIFICATE` set the workflow imports it into a throwaway keychain
that self-locks after 15 minutes. With `MACOS_NOTARY_PASSWORD` set it also
submits the app to Apple's notary service, waits for the result, and staples the
ticket to the bundle before the disk image is built.

The release notes adapt automatically: a notarized build tells users it opens
normally, an ad-hoc one tells them how to get past Gatekeeper.

## Homebrew

`Casks/hyperenv.rb` makes this repository a Homebrew tap. Users install with the
two-argument `brew tap` form, which accepts any repository name:

```sh
brew tap iramarfalcao/hyperenv https://github.com/iramarfalcao/hyperenv
brew trust iramarfalcao/hyperenv
brew install --cask hyperenv
```

`brew trust` is required: Homebrew 6 refuses to load a cask from a third-party
tap without it, and the refusal is an error rather than a prompt. It is easy to
leave out of instructions, because a tap you authored yourself is already trusted
on your own machine.

The release workflow rewrites the cask's `version` and `sha256` from the disk
image it just built and commits that back to `main`. A cask carrying a stale
checksum fails installation with a mismatch error that reads like a corrupted
download, so it is not left to be updated by hand.

Two things to know before aiming at the official `homebrew-cask`:

- **It would be rejected today.** Acceptable Casks requires that an app "must
  not require System Integrity Protection or Gatekeeper to be disabled or
  bypassed". Ad-hoc signed builds are quarantined on download and rejected by
  Gatekeeper, and telling users to strip the attribute is exactly that bypass.
  Setting up Developer ID signing and notarization — the secrets above — is the
  prerequisite, not an optional polish.
- **Notability is judged separately.** Homebrew weighs how established a project
  is, so a new repository is unlikely to qualify regardless of signing.

Nothing about the tap depends on either. It works now, and it keeps working if
the cask is later submitted upstream.

To check the cask after editing it, Homebrew requires it to sit inside a tap:

```sh
brew tap-new you/scratch --no-git
cp Casks/hyperenv.rb "$(brew --repository)/Library/Taps/you/homebrew-scratch/Casks/"
brew style --cask you/scratch/hyperenv
brew audit --cask --online you/scratch/hyperenv
brew untap you/scratch
```

## Versioning

[Semantic versioning](https://semver.org). The workflow rejects a tag that is not
`MAJOR.MINOR.PATCH`.

`CURRENT_PROJECT_VERSION` is set to the workflow run number, so two builds of the
same marketing version are still distinguishable.

## Checklist before tagging

- [ ] `Tests/run-core-checks.sh` passes
- [ ] `Tests/run-shell-integration.sh` passes
- [ ] `CHANGELOG.md` has an entry for the version
- [ ] The app launches from a clean `~/.config/hyperenv`
- [ ] Installing the hook, applying, and reverting leave `~/.zprofile` byte-identical
