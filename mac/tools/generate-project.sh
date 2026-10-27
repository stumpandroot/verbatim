#!/bin/bash
# Generates Verbatim.xcodeproj from project.yml with XcodeGen, with or without the Apple Watch app (DESIGN.md §20).
# One switch, VERBOSE_WATCH: unset (or anything but NO) embeds the watch app in the iPhone app, the default. NO leaves
# it out: tools/generate-project.py writes a copy of project.yml without the iPhone app's dependency on the watch app
# (the lines between "# >>> Apple Watch" and "# <<< Apple Watch") next to project.yml, so its paths still resolve, and
# XcodeGen reads that copy. CI's TestFlight job uses NO to retry an upload whose watch app failed to sign.
#   bash mac/tools/generate-project.sh
#   VERBOSE_WATCH=NO bash mac/tools/generate-project.sh
set -euo pipefail
cd "$(dirname "$0")/.."
case "${VERBOSE_WATCH:-YES}" in
  NO|No|no)
    python3 -I tools/generate-project.py --strip project.yml .project-nowatch.yml
    xcodegen generate --quiet --spec .project-nowatch.yml
    echo "Generated Verbatim.xcodeproj without the Apple Watch app (VERBOSE_WATCH=NO)."
    ;;
  *)
    xcodegen generate --quiet
    echo "Generated Verbatim.xcodeproj with the Apple Watch app."
    ;;
esac
