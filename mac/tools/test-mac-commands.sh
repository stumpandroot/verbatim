#!/bin/bash
# Compiles the Mac's command and small-window rules (Verbatim/App/MacCommandRules.swift: Recent dictations' keys and
# hover, the Recording menu, Find in the open transcript, the Library's columns, the inspector's fit, and the side column) with the cases
# in mac-commands-tests/main.swift, runs them, and then checks the sources that use them (the menus, the find bar, the
# Cleaned tab's Undo, and no hidden shortcut buttons). Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-mac-commands.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/App"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/mac-commands-tests" "$m/MacCommandRules.swift" "$here/mac-commands-tests/main.swift"
"$out/mac-commands-tests" "$here/.."
