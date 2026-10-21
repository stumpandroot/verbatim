#!/bin/bash
# Compiles ExportCore.swift (export options, timecodes, text layout, subtitle segmentation) with the cases in
# export-tests/main.swift and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-export.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/export-tests" "$here/../Verbatim/Export/ExportCore.swift" "$here/export-tests/main.swift"
"$out/export-tests"
