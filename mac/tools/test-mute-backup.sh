#!/bin/bash
# Compiles the real MuteRules.swift (DESIGN.md §6.10, A muted microphone) with the cases in mute-backup-tests/main.swift
# and runs them: when exact digital silence counts as muted, when comparing the Mac's two mics does, which inputs the
# iPhone watches, and what the Mac's backup from the built-in mic writes (held quiet audio, the backup's audio in place
# of a mute, the recording's length kept); then, against the sources, that the recorders use them. Needs only a Swift
# toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-mute-backup.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/mute-backup-tests" "$here/../Verbatim/Model/MuteRules.swift" "$here/../Verbatim/Model/RecordingInputRules.swift" "$here/mute-backup-tests/main.swift"
"$out/mute-backup-tests" "$here/.."
