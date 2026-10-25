#!/bin/bash
# Compiles the iPhone transcript scrubber's arithmetic (VerbatimPhone/ScrubMath.swift) with the test cases in
# scrub-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-scrub.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/scrub-tests" "$here/../VerbatimPhone/ScrubMath.swift" "$here/scrub-tests/main.swift"
"$out/scrub-tests"
