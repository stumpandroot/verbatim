#!/bin/bash
# Checks that no model prompt shows a speaker-label example the model can copy ("like 'Name: '"). Then compiles
# CleanupGuard.swift (with the CleanupPrepass rules it uses) and the test cases in
# cleanup-tests/main.swift, and runs them: speaker labels off before the model and back on after, invented labels
# ("Name:") dropped, fillers removed after the model, and saved "Name:" labels hidden. Needs only a Swift toolchain
# (macOS or Linux), not Xcode.
#   bash mac/tools/test-cleanup.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
flow="$here/../Verbatim/Flow"
doc="$here/../Verbatim/Document"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Polish.swift itself needs Apple's Foundation (sentence enumeration), so its prompt is checked as text.
prompts=("$doc/Polish.swift" "$flow/Cleanup.swift" "$flow/DictationFormatter.swift" "$here/../Verbatim/Transcription/Summarizer.swift"
         "$here/../Verbatim/Transcription/TranscriptActions.swift" "$here/../Verbatim/Transcription/AutoLabel.swift")
if grep -n -E "label like|like 'Name|\"Name: |<name>" "${prompts[@]}" | grep -v -E "^[^:]+:[0-9]+:[[:space:]]*///?"; then
  echo "A prompt above shows the model a speaker-label example or placeholder it can copy."; exit 1
fi
echo "ok    no prompt shows a speaker-label example"
swiftc -O -o "$out/cleanup-tests" \
  "$doc/CleanupGuard.swift" \
  "$flow/CleanupPrepass.swift" "$flow/MeaningCheck.swift" "$flow/SpokenCorrections.swift" \
  "$here/cleanup-tests/main.swift"
"$out/cleanup-tests"
