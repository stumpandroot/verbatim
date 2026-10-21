#!/bin/bash
# Compiles MultitrackMath.swift (offset estimation, mic bleed filtering, merging) with the test cases in
# multitrack-tests/ and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-multitrack.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/multitrack-tests" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" "$here/multitrack-tests/Stubs.swift" "$here/multitrack-tests/main.swift"
"$out/multitrack-tests"
