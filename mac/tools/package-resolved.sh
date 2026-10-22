#!/bin/bash
# The Swift package versions every build uses are pinned in mac/Package.resolved (committed). The generated
# Verbatim.xcodeproj is git-ignored, so its own copy is made from that file.
#   bash mac/tools/package-resolved.sh install   after `xcodegen generate`: Xcode resolves to the pinned versions
#   bash mac/tools/package-resolved.sh check     after a build (CI): fails if resolving changed any version, and
#                                                prints the new file so it can be committed on purpose
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
committed="$here/Package.resolved"
generated="$here/Verbatim.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

case "${1:-}" in
  install)
    [ -d "$here/Verbatim.xcodeproj" ] || { echo "Run xcodegen generate first." >&2; exit 1; }
    if [ -f "$committed" ]; then
      mkdir -p "$(dirname "$generated")"
      cp "$committed" "$generated"
      echo "Package versions pinned from mac/Package.resolved"
    else
      echo "mac/Package.resolved is missing; Xcode resolves the newest allowed versions." >&2
    fi
    ;;
  check)
    if [ ! -f "$generated" ]; then echo "::error::Xcode wrote no Package.resolved at $generated"; exit 1; fi
    if [ ! -f "$committed" ]; then
      echo "::error::mac/Package.resolved isn't committed. This build resolved:"
      cat "$generated"
      exit 1
    fi
    if ! diff -u "$committed" "$generated"; then
      echo "::error::Swift package versions changed from mac/Package.resolved. If that's intended, commit the file above as mac/Package.resolved."
      exit 1
    fi
    echo "Swift package versions match mac/Package.resolved."
    ;;
  *)
    echo "usage: $0 install|check" >&2; exit 2 ;;
esac
