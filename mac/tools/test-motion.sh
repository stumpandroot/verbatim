#!/bin/bash
# Compiles the real MotionRules.swift and MotionChecks.swift (DESIGN.md §7, Motion) with the cases in
# motion-tests/main.swift and runs them: how long a toast stays (a message alone as before, one with an action at
# least 8 s and while it's held), when ⌘Z runs a toast's Undo, how a screen arrives after a click or a key, the fade
# keyboard actions get, the swipe hint's loop, and Limit animation's copy in the App Group; then, against the sources,
# that the views use them (the iPhone toast, Recall, the Ribbon and the notch, keyboard navigation, Follow playback,
# counts, onboarding, the keyboard), that no loop repeats forever, and that every .animation is scoped. Needs only a
# Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-motion.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/motion-tests" "$m/MotionRules.swift" "$m/MotionChecks.swift" "$here/motion-tests/main.swift"
"$out/motion-tests" "$here/.."
