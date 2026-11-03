#!/bin/bash
# Verbose for Mac's license (Verbatim/Model/MacLicense.swift): compiles it with Entitlement.swift and the cases in
# mac-license-tests/main.swift: the trial and license as an entitlement, check-ins with Polar, Polar's answers and
# errors, enforcement only in the public build, and the copy. Needs only a Swift toolchain (macOS or Linux).
#   bash mac/tools/test-mac-license.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/mac-license-tests" "$here/../Verbatim/Model/Entitlement.swift" "$here/../Verbatim/Model/MacLicense.swift" "$here/mac-license-tests/main.swift"
"$out/mac-license-tests"
