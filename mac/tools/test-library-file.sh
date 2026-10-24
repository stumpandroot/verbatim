#!/bin/bash
# Compiles LibraryFile.swift (the one check every file name from a transcript record passes before it's joined to a
# library folder) with the test cases in library-file-tests/main.swift, and runs them. Needs only a Swift toolchain
# (macOS or Linux), not Xcode.
#   bash mac/tools/test-library-file.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/library-file-tests" "$here/../Verbatim/Model/LibraryFile.swift" "$here/library-file-tests/main.swift"
"$out/library-file-tests"
