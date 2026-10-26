#!/bin/bash
# Compiles Thoughts and Journal's by-day rules (Verbatim/Model/DayPages.swift: which page a recording lands on with the
# New page each day at setting and after midnight, page order, titles, Copy's text, the month grid, and the Thought
# pad's one-time move into Thoughts) with the cases in thoughts-tests/main.swift, and runs them. Needs only a Swift
# toolchain, not Xcode.
#   bash mac/tools/test-thoughts.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/thoughts-tests" "$here/../Verbatim/Model/DayPages.swift" "$here/thoughts-tests/main.swift"
"$out/thoughts-tests"
