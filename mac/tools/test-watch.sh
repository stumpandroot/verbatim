#!/bin/bash
# Compiles the real WatchTransfer.swift, WatchImport.swift, and WatchChecks.swift (Apple Watch capture, DESIGN.md §20)
# with Marks.swift, ThoughtPages.swift, and Transcript.swift, and runs the checks the iPhone's self-test also runs:
# the transfer metadata both ways, the watch's marks and words, the context the iPhone sends, and the import mapping
# (kind, marks, source). Then checks the switch that leaves the watch app out of the iPhone app
# (VERBOSE_WATCH=NO tools/generate-project.sh) against project.yml. Needs only a Swift toolchain and python3 (macOS or
# Linux), not Xcode.
#   bash mac/tools/test-watch.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/watch-tests" \
  "$m/Transcript.swift" "$m/LibraryFile.swift" "$m/TolerantCoding.swift" "$m/FlowInfo.swift" "$m/CleanedLayer.swift" "$m/Multitrack.swift" \
  "$m/Formats.swift" "$m/CorrectionEdits.swift" "$m/SyncMerge.swift" "$m/Marks.swift" "$m/DayPages.swift" "$m/ThoughtPages.swift" \
  "$m/WatchTransfer.swift" "$m/WatchImport.swift" "$m/WatchChecks.swift" \
  "$here/../Verbatim/Transcription/MultitrackMath.swift" \
  "$here/transcript-tests/Stubs.swift" "$here/watch-tests/StoreStub.swift" "$here/watch-tests/main.swift"
"$out/watch-tests"

# The switch (DESIGN.md §20): VERBOSE_WATCH=NO drops the marked lines, which hold only the iPhone app's dependency on
# the watch app; the watch targets stay defined, and nothing else in project.yml changes.
python3 -I "$here/generate-project.py" --check "$here/../project.yml"
