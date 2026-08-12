#!/bin/bash
# Sets the six repository secrets that make releases notarized.
#
# Run this yourself rather than handing the values to anyone: the certificate
# and both passwords never leave your machine except as GitHub secrets, and
# nothing sensitive is echoed, written to a file that outlives the run, or left
# in your shell history.
#
# Requires a "Developer ID Application" certificate, which needs a paid Apple
# Developer Program membership. The "Apple Development" certificate Xcode creates
# for you is a testing certificate — Apple's notary service rejects it.
#
# It is all-or-nothing on purpose. The release workflow decides whether to sign
# with a real identity by looking at MACOS_SIGN_IDENTITY, so a half-configured
# repository fails every build at the signing step instead of quietly falling
# back to ad-hoc.
#
# Usage: Scripts/setup-notarization.sh

set -euo pipefail

REPO="${REPO:-iramarfalcao/hyperenv}"

die() { printf '\n%s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "The GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || die "Not signed in to GitHub. Run: gh auth login"

# --- 1. The certificate -------------------------------------------------------

echo "==> Looking for a Developer ID Application certificate"
identity="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | head -1 \
  | sed -E 's/.*"(.*)"/\1/')" || true

if [ -z "${identity:-}" ]; then
  cat <<'EOS'

No "Developer ID Application" certificate found in your keychain.

To create one (a paid Apple Developer Program membership is required):

  1. https://developer.apple.com/account/resources/certificates/list
  2. + → Developer ID Application → Continue
  3. Xcode can also do it: Settings → Accounts → Manage Certificates →
     + → Developer ID Application
  4. Make sure the certificate AND its private key are in your login keychain

Then run this script again.
EOS
  exit 1
fi

echo "    found: $identity"

# The team identifier is the parenthesised suffix of the identity name.
team="$(printf '%s' "$identity" | sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/')"
[ "$team" != "$identity" ] || die "Could not read a team ID out of: $identity"
echo "    team:  $team"

# --- 2. Apple ID and app-specific password ------------------------------------

cat <<'EOS'

Notarization signs in to Apple with an app-specific password — not your Apple ID
password. Create one at https://account.apple.com → Sign-In and Security →
App-Specific Passwords.

EOS

read -r -p "Apple ID used for notarization: " apple_id
[ -n "$apple_id" ] || die "An Apple ID is required."

read -r -s -p "App-specific password (not shown): " notary_password
echo
[ -n "$notary_password" ] || die "An app-specific password is required."

echo
echo "==> Checking those credentials against Apple"
if ! xcrun notarytool history \
      --apple-id "$apple_id" --team-id "$team" --password "$notary_password" \
      >/dev/null 2>&1; then
  die "Apple rejected those credentials. Check the Apple ID, the team ID ($team), and that the password is an app-specific one."
fi
echo "    accepted"

# --- 3. Export the certificate ------------------------------------------------

# A random passphrase: it only has to survive the trip to GitHub, and inventing
# one here means there is no password for you to choose, store, or reuse.
p12_password="$(uuidgen)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
p12="$work/certificate.p12"

echo
echo "==> Exporting the certificate (macOS will ask for permission)"
security export -t identities -f pkcs12 -P "$p12_password" -o "$p12" \
  || die "Export failed. The certificate's private key must be in your keychain."
[ -s "$p12" ] || die "Export produced an empty file."

# --- 4. Set the secrets -------------------------------------------------------

echo
echo "==> Setting secrets on $REPO"
base64 -i "$p12" | gh secret set MACOS_CERTIFICATE --repo "$REPO"
printf '%s' "$p12_password"    | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO"
printf '%s' "$identity"        | gh secret set MACOS_SIGN_IDENTITY --repo "$REPO"
printf '%s' "$team"            | gh secret set MACOS_TEAM_ID --repo "$REPO"
printf '%s' "$apple_id"        | gh secret set MACOS_NOTARY_APPLE_ID --repo "$REPO"
printf '%s' "$notary_password" | gh secret set MACOS_NOTARY_PASSWORD --repo "$REPO"

echo
gh secret list --repo "$REPO"

cat <<EOS

Done. The next tag produces a notarized build:

  git tag v1.0.2 && git push origin v1.0.2

The release workflow will sign with the Developer ID, notarize the app, staple
it, build the disk image, notarize and staple that too, and drop the Gatekeeper
note from the release. Nothing else needs changing.

EOS
