#!/bin/bash
# Compiles the consolidation's pure rules (Verbatim/Model/Consolidation.swift: the one-time moves for features that
# merged or retired on October 28, 2026) with the model they read (Templates.swift, TranscriptActionSpecs.swift,
# and Transcript.swift), and runs the cases in consolidation-tests/main.swift. Needs only a Swift
# toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-consolidation.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/consolidation-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/TranscriptActionSpecs.swift" "$m/Templates.swift" "$m/AudioOnly.swift" \
  "$m/Consolidation.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/consolidation-tests/main.swift"
"$out/consolidation-tests"
