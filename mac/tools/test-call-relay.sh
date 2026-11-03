#!/bin/bash
# Record a call from the iPhone (Verbatim/Model/CallRelay.swift): the Mac's state, requests the Mac acts on, the
# files' round trip, and the copy. Needs only a Swift toolchain (macOS or Linux).
#   bash mac/tools/test-call-relay.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/call-relay-tests" "$here/../Verbatim/Model/CallRelay.swift" "$here/call-relay-tests/main.swift"
"$out/call-relay-tests"
