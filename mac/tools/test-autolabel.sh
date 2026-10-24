#!/bin/bash
# Compiles the real KindRule.swift (the automatic kind for recordings, links, and imported media) with Transcript.swift
# and LibraryFilter.swift, and checks the rules. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-autolabel.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/autolabel-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/LibraryFilter.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" "$here/../Verbatim/Transcription/KindRule.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/autolabel-tests/main.swift"
"$out/autolabel-tests"
