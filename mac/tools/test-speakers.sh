#!/bin/bash
# Compiles the real SpeakerTurns.swift (diarizer turns onto transcript lines, word by word) with Transcript.swift and
# checks it against speaker changes from a real podcast import. Needs only a Swift toolchain (macOS or Linux), not
# Xcode.
#   bash mac/tools/test-speakers.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/speaker-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/../Verbatim/Transcription/SpeakerTurns.swift" "$here/transcript-tests/Stubs.swift" "$here/speaker-tests/main.swift"
"$out/speaker-tests"
