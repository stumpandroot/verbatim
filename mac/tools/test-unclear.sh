#!/bin/bash
# Compiles the noisy-recording rules (Verbatim/Transcription/UnclearRules.swift: Whisper's speech clips, unclear spans,
# dropped hallucinations, splits at long pauses, the reading view's marks) and Transcribe again's versions
# (Verbatim/Model/TranscriptVersions.swift: hand edits, speakers and notes carried over, switching back) with the
# real Transcript.swift, and runs the cases in unclear-tests/main.swift on synthetic segments and speech
# probabilities. No audio, and never a private recording. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-unclear.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
tr="$here/../Verbatim/Transcription"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/unclear-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/TranscriptVersions.swift" \
  "$tr/MultitrackMath.swift" "$tr/UnclearRules.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/unclear-tests/main.swift"
"$out/unclear-tests"
