#!/bin/bash
# Compiles the long lists' row rules (Model/ListRows.swift: a card's rows with their hairlines, day groups as one list
# of rows, the ids' fingerprint, and a view's last-value cache) with the cases in list-rows-tests/main.swift, and runs
# them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-list-rows.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/list-rows-tests" "$here/../Verbatim/Model/ListRows.swift" "$here/list-rows-tests/main.swift"
"$out/list-rows-tests"
