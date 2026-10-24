#!/bin/bash
# Compiles the real SpeakerNames.swift (speaker name suggestions) with Transcript.swift and checks the rules against
# a real YouTube transcript (speaker-names-tests/phone-youtube-export.txt) and small made-up ones. Needs only a Swift
# toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-speaker-names.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/speaker-names-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/SpeakerNames.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/speaker-names-tests/main.swift"
"$out/speaker-names-tests" "$here/speaker-names-tests/phone-youtube-export.txt"
