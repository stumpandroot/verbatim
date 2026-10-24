#!/usr/bin/env bash
# Uploads the Developer ID Application identity (and only that identity) and your Apple ID to GitHub, so CI can
# build signed DMGs that sync with iCloud.
#
# Run once (and again after you rotate the certificate):  ~/verbatim/mac/signing-setup.sh
# macOS asks to allow Keychain access; click "Allow" (or enter your Mac password).
#
# What it does:
#   1. Finds the Developer ID Application identity in your login keychain by its SHA-1 hash (asks if you have
#      more than one).
#   2. Exports the login keychain's identities into a password-protected file in a private temporary folder, picks
#      out the one private key that matches that certificate, and builds a new .p12 that holds only that key and
#      certificate. Nothing else from your keychain leaves the Mac.
#   3. Checks the new .p12 holds exactly one key and the right certificate, then uploads it as MACOS_CERTIFICATE
#      with a fresh random password (MACOS_CERTIFICATE_PASSWORD). Secret values go to `gh` on stdin, never on a
#      command line. The temporary folder is deleted when the script exits.
set -euo pipefail
REPO=stumpandroot/verbatim
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# macOS's LibreSSL writes .p12 files that `security import` on the CI runner reads; Homebrew's OpenSSL 3 doesn't
# by default. Use the system one even if Homebrew's comes first in PATH.
OPENSSL=/usr/bin/openssl

command -v gh >/dev/null 2>&1 || { echo "Install the GitHub CLI (brew install gh), run 'gh auth login', then run this again."; exit 1; }
# Where the secrets go: the "release" environment when it exists (the signing jobs in build-swift.yml use it),
# otherwise repository secrets. SECRET_ENV=<name> or SECRET_ENV=none overrides.
SECRET_ENV="${SECRET_ENV:-}"
if [ -z "$SECRET_ENV" ]; then
  if gh api "repos/$REPO/environments/release" >/dev/null 2>&1; then SECRET_ENV=release; else SECRET_ENV=none; fi
fi
SET=(gh secret set -R "$REPO")
if [ "$SECRET_ENV" != none ]; then SET+=(--env "$SECRET_ENV"); WHERE="the \"$SECRET_ENV\" environment"; else WHERE="repository secrets"; fi

# 1. The Developer ID Application identity, by SHA-1.
IDS="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep '"Developer ID Application: ' || true)"
if [ -z "$IDS" ]; then
  echo "No Developer ID Application certificate in your login keychain."
  echo "In Xcode: Settings › Accounts › your Apple ID › Manage Certificates › + › Developer ID Application."
  echo "Then run this script again."
  open -a Xcode || true
  exit 1
fi
COUNT="$(printf '%s\n' "$IDS" | wc -l | tr -d ' ')"
if [ "$COUNT" -gt 1 ]; then
  echo "More than one Developer ID Application identity is in your login keychain:"
  printf '%s\n' "$IDS" | awk '{ $1=""; print "  " NR ")" $0 }'
  read -r -p "Number of the one CI should sign with: " PICK
  [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le "$COUNT" ] || { echo "Not a number from the list."; exit 1; }
  LINE="$(printf '%s\n' "$IDS" | sed -n "${PICK}p")"
else
  LINE="$IDS"
fi
SHA1="$(printf '%s\n' "$LINE" | awk '{print $2}')"
NAME="$(printf '%s\n' "$LINE" | grep -o '"Developer ID Application: [^"]*"' | tr -d '"')"
[[ "$SHA1" =~ ^[0-9A-F]{40}$ ]] || { echo "Couldn't read the certificate's SHA-1 hash."; exit 1; }
echo "✓ Using: $NAME"
echo "  SHA-1: $SHA1"

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

# 2a. The certificate itself, matched by SHA-1 (find-certificate prints "SHA-1 hash: …" before each PEM).
security find-certificate -a -Z -p -c "Developer ID Application" "$KEYCHAIN" | awk -v want="$SHA1" '
  /^SHA-1 hash:/ { keep = ($3 == want); next }
  keep && /-----BEGIN CERTIFICATE-----/ { out = 1 }
  out { print }
  out && /-----END CERTIFICATE-----/ { exit }
' > "$TMP/cert.pem"
grep -q "BEGIN CERTIFICATE" "$TMP/cert.pem" || { echo "Couldn't find the certificate with SHA-1 $SHA1."; exit 1; }
GOT="$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')"
[ "$GOT" = "$SHA1" ] || { echo "The certificate found doesn't match SHA-1 $SHA1."; exit 1; }
CERT_PUB="$("$OPENSSL" x509 -in "$TMP/cert.pem" -noout -pubkey)"

# 2b. `security export` can't pick one identity, so export them all to a protected file that never leaves this
# folder, then keep only the private key whose public half matches the certificate.
ALL_PASS="$("$OPENSSL" rand -hex 24)"; export ALL_PASS
echo "Reading your keychain's identities (macOS may ask to allow this; nothing is uploaded yet)…"
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$ALL_PASS" -o "$TMP/all.p12"
if ! KEYS="$("$OPENSSL" pkcs12 -in "$TMP/all.p12" -passin env:ALL_PASS -nocerts -nodes 2>/dev/null)"; then
  rm -f "$TMP/all.p12"
  echo "Couldn't read the exported identities with $OPENSSL. Nothing was uploaded. Export by hand instead:"
  echo "  1. In Keychain Access › login › My Certificates, select only \"$NAME\"."
  echo "  2. File › Export Items… › Personal Information Exchange (.p12), with a new password."
  echo "  3. base64 -i <file>.p12 | ${SET[*]} MACOS_CERTIFICATE"
  echo "  4. ${SET[*]} MACOS_CERTIFICATE_PASSWORD   (type the password when asked), then delete the .p12."
  exit 1
fi
rm -f "$TMP/all.p12"
N="$(printf '%s\n' "$KEYS" | grep -c -- '-----BEGIN .*PRIVATE KEY-----' || true)"
MATCH=""
for i in $(seq 1 "$N"); do
  K="$(printf '%s\n' "$KEYS" | awk -v n="$i" '
    /-----BEGIN .*PRIVATE KEY-----/ { c++ }
    c == n { print }
    c == n && /-----END .*PRIVATE KEY-----/ { exit }
  ')"
  if [ "$(printf '%s\n' "$K" | "$OPENSSL" pkey -pubout 2>/dev/null)" = "$CERT_PUB" ]; then MATCH="$K"; break; fi
done
unset KEYS
[ -n "$MATCH" ] || { echo "No private key in your login keychain matches that certificate."; exit 1; }

# 2c. A new .p12 with just that key and certificate, under a fresh random password.
PASS="$("$OPENSSL" rand -hex 24)"; export PASS
printf '%s\n' "$MATCH" | "$OPENSSL" pkcs12 -export -inkey /dev/stdin -in "$TMP/cert.pem" \
  -name "$NAME" -passout env:PASS -out "$TMP/devid.p12"
unset MATCH

# 3. Check it holds exactly one key and only this certificate before anything is uploaded.
NKEYS="$("$OPENSSL" pkcs12 -in "$TMP/devid.p12" -passin env:PASS -nocerts -nodes 2>/dev/null | grep -c -- '-----BEGIN .*PRIVATE KEY-----' || true)"
NCERTS="$("$OPENSSL" pkcs12 -in "$TMP/devid.p12" -passin env:PASS -nokeys 2>/dev/null | grep -c -- '-----BEGIN CERTIFICATE-----' || true)"
P12_SHA1="$("$OPENSSL" pkcs12 -in "$TMP/devid.p12" -passin env:PASS -nokeys 2>/dev/null | "$OPENSSL" x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')"
if [ "$NKEYS" != 1 ] || [ "$NCERTS" != 1 ] || [ "$P12_SHA1" != "$SHA1" ]; then
  echo "The new .p12 doesn't hold exactly the Developer ID identity (keys: $NKEYS, certificates: $NCERTS). Nothing was uploaded."
  exit 1
fi
echo "✓ Built a .p12 with one key and one certificate ($NAME)"

base64 -i "$TMP/devid.p12" | "${SET[@]}" MACOS_CERTIFICATE
printf '%s' "$PASS" | "${SET[@]}" MACOS_CERTIFICATE_PASSWORD
unset PASS ALL_PASS
echo "✓ Uploaded MACOS_CERTIFICATE and MACOS_CERTIFICATE_PASSWORD to $WHERE"

read -r -p "Email address of your Apple developer account: " APPLE_ID
printf '%s' "$APPLE_ID" | "${SET[@]}" APPLE_ID
echo "✓ Uploaded APPLE_ID to $WHERE"

cat <<EOF

Done. Next steps:
  1. The secrets went to $WHERE. If you later create the "release" environment, run this script again so they
     go there, then delete the repository-level copies (Settings › Secrets and variables › Actions).
  2. If you ran an older version of this script, the old MACOS_CERTIFICATE held every identity in your login
     keychain, not only Developer ID. These are the identities in that keychain now:
EOF
security find-identity -v "$KEYCHAIN" | sed 's/^/       /'
cat <<EOF
     Revoke and reissue any of them that CI doesn't need (Apple ones at developer.apple.com › Certificates;
     others with whoever issued them). CI needs only "$NAME".
  3. Start a build of main (Actions › Build Mac app (SwiftUI) › Run workflow) and check the log says
     "Signing as: $NAME".
EOF
