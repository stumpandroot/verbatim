#!/bin/bash
# Compiles the real Ask.swift, AskRecipes.swift, and AskChecks.swift (Ask your library and recipes) with Transcript.swift,
# and runs the cases in ask-tests/main.swift plus the checks both self-tests run: scopes, passages, ranking and the
# relevance floor, digests, the prompt, citation checking and renumbering, the footer, recipe scheduling (the next run,
# a missed run caught up once and not again), and recipes syncing. Needs only a Swift toolchain (macOS or Linux).
#   bash mac/tools/test-ask.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/ask-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/Ask.swift" "$m/AskRecipes.swift" "$m/AskChecks.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/ask-tests/main.swift"
"$out/ask-tests" "$here/.."
