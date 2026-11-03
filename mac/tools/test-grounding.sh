#!/bin/bash
# Compiles the real Grounding.swift (the AI output checks) and Grounding+Results.swift (summaries, template results,
# Plan my day, and Ask answers) with Transcript.swift, Templates.swift, DayPlan.swift, and Ask.swift, and runs the cases
# in grounding-tests/main.swift: numbers written and spelled out, money, percentages, times, dates, names with
# possessives, quotes, citations, plans' days and Top three, long transcripts, contradictory and missing evidence, the
# false-positive guards, and the note's wording. Needs only a Swift toolchain (macOS or Linux).
#   bash mac/tools/test-grounding.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/grounding-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/TranscriptActionSpecs.swift" "$m/Templates.swift" \
  "$m/AudioOnly.swift" "$m/DayPlan.swift" "$m/TaskSend.swift" "$m/Ask.swift" "$m/AskRecipes.swift" \
  "$m/Grounding.swift" "$m/Grounding+Results.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/grounding-tests/main.swift"
"$out/grounding-tests" "$here/.."
