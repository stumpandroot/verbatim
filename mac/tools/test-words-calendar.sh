#!/bin/bash
# Compiles the real WordsCalendar.swift and WordsCalendarChecks.swift (your words calendar on the You page) and runs
# the checks both self-tests also run. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-words-calendar.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m="$here/../Verbatim/Model"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/words-calendar-tests" "$m/WordsCalendar.swift" "$m/WordsCalendarChecks.swift" "$here/words-calendar-tests/main.swift"
"$out/words-calendar-tests"
