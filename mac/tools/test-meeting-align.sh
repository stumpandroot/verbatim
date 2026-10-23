#!/bin/bash
# Compiles MeetingAlign.swift (meeting capture: the sidecar, track clocks, silence and zero-buffer detection, and
# lining the mic and system tracks up) with the test cases in meeting-align-tests/main.swift, and runs them. Needs
# only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-meeting-align.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/meeting-align-tests" "$here/../Verbatim/Audio/MeetingAlign.swift" "$here/meeting-align-tests/main.swift"
"$out/meeting-align-tests"
