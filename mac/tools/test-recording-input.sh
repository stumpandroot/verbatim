#!/bin/bash
# Compiles the real RecordingInputRules.swift (DESIGN.md §6.10, Recording input) with the cases in
# recording-input-tests/main.swift and runs them: which microphone an iPhone recording uses (the one you chose, then
# the accessory iOS routes to, then any accessory, then the iPhone's), the Record card's ready chip from a mocked
# route, the recorder's microphone menu, the audio session's mode and AirPods high-quality option, and what a route
# change does to a running recording; then, against the sources, that the iPhone sets the input before the session
# activates and never asks for the high-quality option outside the default mode. Needs only a Swift toolchain (macOS
# or Linux), not Xcode.
#   bash mac/tools/test-recording-input.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/recording-input-tests" "$here/../Verbatim/Model/RecordingInputRules.swift" "$here/recording-input-tests/main.swift"
"$out/recording-input-tests" "$here/.."
