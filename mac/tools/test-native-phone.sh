#!/bin/bash
# Compiles the iPhone's Native look rules (VerbatimPhone/NativeRules.swift: the recorder's clock and ruler, Settings'
# square colors, and This week's line) with the cases in native-phone-tests/main.swift, and runs them. The cases also
# read the iPhone's Native look code and check that none of Premium Native's retired chrome is left in it (persimmon,
# the brand accent, gradient cards, glows, custom shadows, SF Pro Rounded numbers). Needs only a Swift toolchain
# (macOS or Linux), not Xcode.
#   bash mac/tools/test-native-phone.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/native-phone-tests" "$here/../VerbatimPhone/NativeRules.swift" "$here/native-phone-tests/main.swift"
"$out/native-phone-tests" "$here/../VerbatimPhone"
