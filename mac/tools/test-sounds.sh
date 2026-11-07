#!/bin/bash
# Compiles the real SoundRules.swift and SoundChecks.swift (DESIGN.md §7, Sounds) with the cases in sounds-tests/main.swift
# and runs them: the eleven moments, the 150 ms rule that drops a second sound, and the start sound playing before the
# microphone keeps anything (MicArm; nothing is silenced); then the files (every moment has its 48 kHz mono 16-bit CAF, as long as the rules say, and
# a row in the README with its source and license), the project (both apps bundle them), and the sources (no system
# sounds left, no sound on a copy or a move, starts played before the mic with the recording armed after them, stops after the mic is off, the meeting
# tracks leaving Verbose's own audio out). Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-sounds.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/sounds-tests" "$m/SoundRules.swift" "$m/SoundChecks.swift" "$here/sounds-tests/main.swift"
"$out/sounds-tests" "$here/.."
