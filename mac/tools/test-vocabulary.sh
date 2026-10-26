#!/bin/bash
# The word patch gate: checks the built-in vocabulary (Verbatim/Resources/ModernVocabulary.json) and the everyday
# fixes (Verbatim/Resources/EverydayFixes.json) with vocab_check.py: schema, duplicates, common English words in
# heard forms, longest-match order, every fix's examples, and the ordinary sentences in
# vocab-fixtures/negatives.txt that nothing may change. Then compiles the app's own BuiltInVocabulary.swift and
# EverydayFixes.swift (with vocabulary-tests/main.swift) and checks they give the gate's results on every case, so
# the gate's Python matching stays the app's. Needs python3 and a Swift toolchain (macOS or Linux), not Xcode.
# mac/Vocabulary/README.md has the monthly routine.
#   bash mac/tools/test-vocabulary.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
res="$here/../Verbatim/Resources"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

python3 -I "$here/vocab_check.py"
python3 -I "$here/vocab_check.py" --emit-parity "$out/cases.json"
swiftc -O -o "$out/vocabulary-tests" \
  "$here/../Verbatim/Model/BuiltInVocabulary.swift" "$here/../Verbatim/Flow/EverydayFixes.swift" \
  "$here/vocabulary-tests/main.swift"
"$out/vocabulary-tests" "$res/ModernVocabulary.json" "$res/EverydayFixes.json" "$out/cases.json"
