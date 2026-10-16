#!/usr/bin/env bash
# Uploads the Developer ID certificate and your Apple ID to GitHub so CI can build DMGs that sync with iCloud.
# Run once:  ~/verbatim/mac/signing-setup.sh
# macOS asks to allow Keychain access; click "Always Allow" (or enter your Mac password).
set -euo pipefail
REPO=stumpandroot/verbatim

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No Developer ID Application certificate on this Mac."
  echo "In Xcode: Settings › Accounts › your Apple ID › Manage Certificates › + › Developer ID Application."
  echo "Then run this script again."
  open -a Xcode
  exit 1
fi
echo "✓ Found: $(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"
echo "Exporting the certificate (macOS may ask you to allow this)…"
security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "$PASS" -o "$TMP/cert.p12"
base64 -i "$TMP/cert.p12" | gh secret set MACOS_CERTIFICATE -R "$REPO"
gh secret set MACOS_CERTIFICATE_PASSWORD -R "$REPO" -b "$PASS"

read -r -p "Email address of your Apple developer account: " APPLE_ID
gh secret set APPLE_ID -R "$REPO" -b "$APPLE_ID"

echo
echo "✓ Done. Tell Claude, and it will start a signed build that syncs with iCloud."
