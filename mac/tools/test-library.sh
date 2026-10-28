#!/bin/bash
# Compiles the real LibraryFilter.swift (the Library's types, platforms, and the refined look's quick filter chips) with
# Transcript.swift, and checks the chips: their order, what each one filters by, which chip shows a filter, and the
# name of a filter the chips don't name. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-library.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/library-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/LibraryFilter.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/library-tests/main.swift"
"$out/library-tests"
