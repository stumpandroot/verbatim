#!/bin/bash
# Compiles AudioNaming.swift (unique names for new audio files, and claiming a file without replacing one) with the
# test cases in naming-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-naming.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/naming-tests" "$here/../Verbatim/Model/AudioNaming.swift" "$here/naming-tests/main.swift"
"$out/naming-tests"
