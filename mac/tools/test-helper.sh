#!/bin/bash
# Compiles HelperProcess.swift (the yt-dlp runner and its command lines) with the test cases in helper-tests/main.swift
# and runs them against fake helpers: shell scripts that print and exit at once, leave a child printing, fail, or
# run until cancelled. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-helper.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/helper-tests" "$here/../Verbatim/Sources/HelperProcess.swift" "$here/helper-tests/main.swift"
"$out/helper-tests"
