#!/bin/bash
# Compiles the trust features' pure logic (Local Only and the network activity log, Fix all's matching, and the
# Dictionary's CSV import and export) with the cases in privacy-tests/main.swift and runs them. Needs only a Swift
# toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-privacy.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/privacy-tests" "$here/../Verbatim/Model/NetworkActivity.swift" "$here/../Verbatim/Model/CorrectEverywhere.swift" \
    "$here/../Verbatim/Model/DictionaryCSV.swift" "$here/privacy-tests/main.swift"
"$out/privacy-tests"
