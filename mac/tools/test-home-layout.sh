#!/bin/bash
# Compiles Edit Home's layout model (Verbatim/Model/HomeLayout.swift: each look's defaults on each app, carrying over
# the older Home settings, tolerant decoding of stored layouts, the editor's moves, the four tiles, and the Mac's 7 / 5
# pairing) with the cases in home-layout-tests/main.swift, and runs them. Needs only a Swift toolchain, not Xcode.
#   bash mac/tools/test-home-layout.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/home-layout-tests" "$here/../Verbatim/Model/HomeLayout.swift" "$here/home-layout-tests/main.swift"
"$out/home-layout-tests"
