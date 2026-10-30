#!/bin/bash
# The iPhone's system surfaces after the build 228 review (W-01 to W-10): the Live Activities' timers, buttons, labels,
# and Lock Screen colors, the controls' custom symbols and the Action button control's name (VerbatimWidgets/
# RibbonRules.swift), the widgets' names and type sizes, and the keyboard's text on the persimmon fill. Widgets can't be
# screenshot in CI, so these read the rules, the tokens (Tokens.swift), and the sources. Needs only a Swift toolchain
# (macOS or Linux), not Xcode.
#   bash mac/tools/test-live-activity.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/live-activity-tests" "$here/../VerbatimWidgets/RibbonRules.swift" "$here/live-activity-tests/main.swift"
"$out/live-activity-tests" "$here/.."
