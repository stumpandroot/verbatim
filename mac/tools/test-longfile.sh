#!/bin/bash
# Compiles LongFilePlan.swift (section boundaries, quiet cuts, stitching) and LanguageRules.swift (language guesses
# and routes) with the test cases in longfile-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS
# or Linux), not Xcode.
#   bash mac/tools/test-longfile.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
t="$here/../Verbatim/Transcription"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/longfile-tests" "$t/LongFilePlan.swift" "$t/LanguageRules.swift" "$here/longfile-tests/main.swift"
"$out/longfile-tests"
