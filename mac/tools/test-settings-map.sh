#!/bin/bash
# Compiles the Settings layouts (VerbatimPhone/PhoneSettingsMap.swift and Verbatim/Views/MacSettingsMap.swift) with the cases
# in settings-map-tests/main.swift and runs them against the sources: every setting and every stored key appears
# exactly once, every search entry is in the layout with its group and target, every page and pane exists, and every
# row a search result lands on has its id. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-settings-map.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/settings-map-tests" "$here/../VerbatimPhone/PhoneSettingsMap.swift" "$here/../Verbatim/Views/MacSettingsMap.swift" "$here/settings-map-tests/main.swift"
"$out/settings-map-tests" "$here/.."
