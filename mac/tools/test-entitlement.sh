#!/bin/bash
# Verbose Unlock on iPhone (Verbatim/Model/Entitlement.swift, DESIGN.md §21): compiles the model with the cases in
# entitlement-tests/main.swift and runs them: the state a device's transactions add up to (none, the trial with its
# days left, the trial ended, unlocked; refunds and revocations), the gate shared code reads, the 10-minute limit,
# Home's cards and their dismissals, the Settings row, the copy's rules, the stand-in store, and the iPhone sources'
# wiring (the products, the gated entry points, no outside purchase links). Needs only a Swift toolchain (macOS or
# Linux), not Xcode.
#   bash mac/tools/test-entitlement.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/entitlement-tests" "$here/../Verbatim/Model/Entitlement.swift" "$here/entitlement-tests/main.swift"
"$out/entitlement-tests" "$here/.."
