#!/bin/bash
# Compiles MP4Timing.swift (an MP4's real length, for YouTube's fragmented M4A), LinkChunks.swift (the chunked
# download's byte ranges), and YouTubePageMeta.swift (a video's channel and upload date) with their checks. No
# network. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-linkmedia.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/linkmedia-tests" \
  "$here/../Verbatim/Sources/MP4Timing.swift" "$here/../VerbatimPhone/LinkChunks.swift" "$here/../VerbatimPhone/YouTubePageMeta.swift" \
  "$here/linkmedia-tests/main.swift"
"$out/linkmedia-tests"
