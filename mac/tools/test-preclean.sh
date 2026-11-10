#!/bin/bash
# Compiles the rules for clean while you talk (Model/PreClean.swift: sealing finished sentences, matching them
# against the final text, pacing, the audio so far, and one dictation's session with a stand-in for the model) with
# the cases in pre-clean-tests/main.swift and the shared checks (Model/PreCleanChecks.swift), and runs them. Needs
# only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-preclean.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/pre-clean-tests" \
  "$m/PreClean.swift" "$m/PreCleanChecks.swift" "$here/pre-clean-tests/main.swift"
"$out/pre-clean-tests"
