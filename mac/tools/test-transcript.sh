#!/bin/bash
# Compiles the real Transcript.swift (with TolerantCoding.swift and stand-ins for the app types it touches) and
# round-trips a transcript file from a newer build (transcript-tests/future-transcript.json): unknown enum values,
# unknown keys, and schemaVersion survive a save. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-transcript.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/transcript-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/transcript-tests/main.swift"
"$out/transcript-tests" "$here/transcript-tests/future-transcript.json"
