#!/bin/bash
# Compiles the widgets' snapshot (VerbatimWidgets/WidgetSnapshot.swift: what the app writes for the Home Screen and
# desktop widgets, its encoding and privacy limits, the week's counts, and the verbatim:// links the widgets open) with
# the cases in widget-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-widgets.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/widget-tests" "$here/../VerbatimWidgets/WidgetSnapshot.swift" "$here/widget-tests/main.swift"
"$out/widget-tests"
