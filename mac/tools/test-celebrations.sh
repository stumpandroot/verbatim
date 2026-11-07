#!/bin/bash
# Compiles the real CelebrationRules.swift, CelebrationChecks.swift, and SoundRules.swift (DESIGN.md §7, Celebrations)
# with the cases in celebration-tests/main.swift and runs them: the timings and sizes, the words, the colors, which
# surface shows a finished transcript (never a dictation or a thought), whether finishing a recording celebrates, the
# watch's ring, a row waiting for a swipe, and the word milestones with their queue and store; then, against the
# sources, that the views and both apps use them (the overlay never takes a tap or changes layout, Limit animation
# crossfades, VoiceOver hears the word, the haptics, the pale transcribing badge, no celebration in the keyboard or
# the Mac's status-bar panels). Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-celebrations.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/celebration-tests" "$m/CelebrationRules.swift" "$m/CelebrationChecks.swift" "$m/SoundRules.swift" "$here/celebration-tests/main.swift"
"$out/celebration-tests" "$here/.."
