#!/bin/bash
# Compiles the real VoiceShadow.swift ("Only keep my voice in dictation" as pure rules) with the cases in
# voice-shadow-tests/main.swift and runs them: which words the filter drops, why it keeps every word, the numbers kept
# per dictation (never a word or audio), the stored list's cap, when shadow mode runs, and the threshold report by
# turn length; then, against the sources, that the real filter and shadow mode share one decision, that shadow scoring
# starts only after the paste, and that deleting the voice profile deletes the records. Needs only a Swift toolchain
# (macOS or Linux), not Xcode.
#   bash mac/tools/test-voice-shadow.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/voice-shadow-tests" "$here/../Verbatim/Model/VoiceShadow.swift" "$here/voice-shadow-tests/main.swift"
"$out/voice-shadow-tests" "$here/.."
