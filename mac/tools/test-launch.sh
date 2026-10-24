#!/bin/bash
# Compiles LaunchBudget.swift (the deadline launch's iCloud reads share, what happens once it runs out, and the gate
# that lets launch stop waiting for a file coordinator) with the test cases in launch-tests/main.swift, and runs
# them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-launch.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/launch-tests" "$here/../Verbatim/Model/LaunchBudget.swift" "$here/launch-tests/main.swift"
"$out/launch-tests"
