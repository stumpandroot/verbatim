#!/bin/bash
# Compiles the recording ribbon's rules (VerbatimWidgets/RibbonRules.swift: where a finished take goes, the take
# state machine, the idle timeout and the 8-hour cap, the Action button choice, and the Live Activity's words) with
# the cases in ribbon-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-ribbon.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/ribbon-tests" "$here/../VerbatimWidgets/RibbonRules.swift" "$here/ribbon-tests/main.swift"
"$out/ribbon-tests"
