#!/bin/bash
# Compiles MeetingDetect.swift (noticing a call: which app is using the microphone, when to ask, one prompt per
# call, and the per-app consent counts) with the test cases in meeting-detect-tests/main.swift, and runs them. Needs
# only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-meeting-detect.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/meeting-detect-tests" "$here/../Verbatim/Audio/MeetingDetect.swift" "$here/meeting-detect-tests/main.swift"
"$out/meeting-detect-tests"
