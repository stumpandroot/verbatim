#!/bin/bash
# Compiles MeetingNames.swift (a calendar call's names: who the call's track is, the meeting's word list, and misheard
# names fixed after the call), CallWindowNames.swift (names and a meeting title from the call app's window),
# CallNameChecks.swift (the checks the Mac's self-test runs too), and MeetingTurns.swift (lines from two tracks tidied
# into turns) with SpeakerNames.swift, Transcript.swift, and CorrectionEdits.swift, and runs the cases in
# meeting-names-tests/main.swift. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-meeting-names.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
tr="$here/../Verbatim/Transcription"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/meeting-names-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/SpeakerNames.swift" "$m/MeetingNames.swift" \
  "$m/CallWindowNames.swift" "$m/CallNameChecks.swift" \
  "$m/TranscriptVersions.swift" "$tr/MultitrackMath.swift" "$tr/MeetingTurns.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/meeting-names-tests/main.swift"
"$out/meeting-names-tests"
