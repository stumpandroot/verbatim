#!/bin/bash
# Compiles the real Marks.swift and MarkChecks.swift (mark a moment while recording) with Transcript.swift, and runs
# the checks both self-tests also run: dedupe, marks as bookmarks, snapping to the line being said, quotes, sources,
# the ".marks" file beside a recording, and sync. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-marks.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/marks-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/Marks.swift" "$m/MarkChecks.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/marks-tests/main.swift"
"$out/marks-tests"
