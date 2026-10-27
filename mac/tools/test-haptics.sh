#!/bin/bash
# Compiles the real HapticPolicy.swift and HapticChecks.swift (DESIGN.md §7, Haptics) with the cases in
# haptics-tests/main.swift and runs them: which event plays which haptic on the iPhone, the keyboard, and the Apple
# Watch, the switch turning them all off, transcript ready once per recording, and the keyboard's typing taps off by
# default; then, against the sources, every recording session allowing haptics before it activates, every haptic
# going through the policy, and start and stop playing at the right moment. Needs only a Swift toolchain (macOS or
# Linux), not Xcode.
#   bash mac/tools/test-haptics.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/haptics-tests" "$m/HapticPolicy.swift" "$m/HapticChecks.swift" "$here/haptics-tests/main.swift"
"$out/haptics-tests" "$here/.."
