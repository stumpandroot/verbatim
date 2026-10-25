#!/bin/bash
# Compiles LookRules.swift (the Native look's token roles, SF Symbols, title case, and welcome tour steps) with the
# test cases in native-tests/main.swift, and runs them; they also read Tokens.swift for the accent's contrast. Needs
# only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-native.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/native-tests" "$here/../Verbatim/Views/LookRules.swift" "$here/native-tests/main.swift"
"$out/native-tests" "$here/../Verbatim/Views/Tokens.swift"
