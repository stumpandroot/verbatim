#!/bin/bash
# Compiles SyncMerge.swift (merging projects, the Dictionary, and snippets entry by entry, with tombstones for
# deletes) with the test cases in sync-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or
# Linux), not Xcode.
#   bash mac/tools/test-sync.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/sync-tests" "$here/../Verbatim/Model/SyncMerge.swift" "$here/sync-tests/main.swift"
"$out/sync-tests"
