#!/bin/bash
# Compiles CloudShareLink.swift and LinkSignIn.swift with their checks (CloudShareLinkChecks, LinkSignInChecks) and
# runs them: URL resolution, Drive's virus-scan page, iCloud's answer, Content-Disposition, and yt-dlp's sign-in
# errors. No network. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-cloudlinks.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../Verbatim/Sources"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/cloudlink-tests" \
  "$src/CloudShareLink.swift" "$src/CloudShareLinkChecks.swift" "$src/LinkSignIn.swift" "$here/cloudlink-tests/main.swift"
"$out/cloudlink-tests"
