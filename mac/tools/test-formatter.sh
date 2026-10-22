#!/bin/bash
# Compiles DictationFormatter.swift (with the CleanupPrepass, NumberWords, and AppCategory code it uses) and the
# destination checks with the test cases in formatter-tests/main.swift, and runs them. Needs only a Swift
# toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-formatter.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
flow="$here/../Verbatim/Flow"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/formatter-tests" \
  "$flow/DictationFormatter.swift" "$flow/CleanupPrepass.swift" "$flow/MeaningCheck.swift" "$flow/DestinationChecks.swift" \
  "$flow/SpokenCorrections.swift" "$flow/SpokenCorrectionsChecks.swift" \
  "$here/../Verbatim/Model/FlowInfo.swift" "$here/../Verbatim/Model/TolerantCoding.swift" \
  "$here/../Verbatim/Model/DictationTiming.swift" "$here/formatter-tests/main.swift"
"$out/formatter-tests"
