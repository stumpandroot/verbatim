#!/bin/bash
# Compiles the real Templates.swift (templates, Run automatically's rules, results, and Record a kind) with
# TranscriptActionSpecs.swift and Transcript.swift, and runs the cases in templates-tests/main.swift: the library, the
# no-add rule in every prompt, the per-kind assignment, the skip rules, run once per recording, a picked kind winning
# over the guess, and the kind-change offer. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-templates.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/templates-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/TranscriptActionSpecs.swift" "$m/Templates.swift" "$m/TemplateChecks.swift" "$m/AudioOnly.swift" "$m/DayPlan.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/templates-tests/main.swift"
"$out/templates-tests"
