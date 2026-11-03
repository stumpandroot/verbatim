#!/bin/bash
# Compiles CallPlan.swift (recording a call before it starts: call links in calendar events, which call is next, the
# wait and when it fires, when a call has ended, and which call-window frames to keep as stills) with MeetingDetect.swift
# and the test cases in call-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-calls.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/call-tests" "$here/../Verbatim/Audio/MeetingDetect.swift" "$here/../Verbatim/Audio/CallPlan.swift" "$here/call-tests/main.swift"
"$out/call-tests"
