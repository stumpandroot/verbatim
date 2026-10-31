#!/bin/bash
# Generates Verbatim.xcodeproj from project.yml with XcodeGen (DESIGN.md §20). Two switches:
# - VERBOSE_WATCH: unset (or anything but NO) embeds the watch app in the iPhone app, the default. NO leaves it out
#   (the lines between "# >>> Apple Watch" and "# <<< Apple Watch"). CI's TestFlight job uses NO to retry an upload
#   whose watch app failed to sign.
# - VERBOSE_YOUTUBEKIT: unset links YouTubeKit into the iPhone app, for your own builds that fetch YouTube on the
#   iPhone. NO leaves it out (the lines between "# >>> YouTubeKit" and "# <<< YouTubeKit"), so App Store builds don't
#   ship it or its JavaScript bundle (App Review AR-05). CI's public TestFlight track uses NO.
# tools/generate-project.py writes the trimmed copy next to project.yml, so its paths still resolve, and XcodeGen
# reads that copy.
#   bash mac/tools/generate-project.sh
#   VERBOSE_WATCH=NO VERBOSE_YOUTUBEKIT=NO bash mac/tools/generate-project.sh
set -euo pipefail
cd "$(dirname "$0")/.."
spec=project.yml
notes=()
case "${VERBOSE_WATCH:-YES}" in
  NO|No|no)
    python3 -I tools/generate-project.py --strip "$spec" .project-nowatch.yml
    spec=.project-nowatch.yml
    notes+=("without the Apple Watch app (VERBOSE_WATCH=NO)")
    ;;
  *) notes+=("with the Apple Watch app") ;;
esac
case "${VERBOSE_YOUTUBEKIT:-YES}" in
  NO|No|no)
    python3 -I tools/generate-project.py --strip-youtubekit "$spec" .project-noyoutubekit.yml
    spec=.project-noyoutubekit.yml
    notes+=("without YouTubeKit (VERBOSE_YOUTUBEKIT=NO)")
    ;;
esac
if [ "$spec" = project.yml ]; then xcodegen generate --quiet; else xcodegen generate --quiet --spec "$spec"; fi
echo "Generated Verbatim.xcodeproj ${notes[*]}."
