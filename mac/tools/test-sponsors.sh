#!/bin/bash
# Compiles the sponsor rules (Transcription/SponsorDetect.swift, Model/Sponsors.swift) with the real Transcript.swift
# and runs them against a real podcast episode (sponsor-tests/podcast-export.txt, five sponsor reads mostly inside the
# host's turns): each read is found, named, and bounded, the interview isn't flagged, and folding, skipping, marking,
# and leaving reads out of summaries and exports work. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-sponsors.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/sponsor-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/Sponsors.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" "$here/../Verbatim/Transcription/SponsorDetect.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/sponsor-tests/main.swift"
"$out/sponsor-tests" "$here/sponsor-tests/podcast-export.txt"
