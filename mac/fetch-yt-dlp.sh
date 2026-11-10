#!/bin/bash
# Downloads the pinned yt-dlp standalone macOS binary (universal) into mac/Helpers, the Mac app's link helper, and
# checks its SHA-256 against the value yt-dlp publishes in that release's SHA2-256SUMS. A mismatch stops the build
# and leaves nothing behind. Used by build.sh and setup.sh.
#   bash mac/fetch-yt-dlp.sh
# Another release: set YTDLP_VERSION and YTDLP_SHA256 (the yt-dlp_macos line of its SHA2-256SUMS).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/Helpers"

PINNED_VERSION="2026.10.26"
# https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/SHA2-256SUMS, the yt-dlp_macos line.
PINNED_SHA256="0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa"

YTDLP_VERSION="${YTDLP_VERSION:-$PINNED_VERSION}"
if [ "$YTDLP_VERSION" = "$PINNED_VERSION" ]; then
  want="${YTDLP_SHA256:-$PINNED_SHA256}"
else
  want="${YTDLP_SHA256:?Set YTDLP_SHA256 to the yt-dlp_macos checksum in the SHA2-256SUMS of yt-dlp $YTDLP_VERSION}"
fi

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

mkdir -p "$dest"
if [ -x "$dest/yt-dlp" ] && grep -qx "$YTDLP_VERSION" "$dest/yt-dlp.version" 2>/dev/null && [ "$(sha256 "$dest/yt-dlp")" = "$want" ]; then
  exit 0
fi

tmp="$(mktemp "$dest/.yt-dlp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"
got="$(sha256 "$tmp")"
if [ "$got" != "$want" ]; then
  echo "yt-dlp $YTDLP_VERSION checksum mismatch: expected $want, got $got. Not installing it." >&2
  exit 1
fi
chmod +x "$tmp"
mv "$tmp" "$dest/yt-dlp"
echo "$YTDLP_VERSION" > "$dest/yt-dlp.version"
echo "yt-dlp $YTDLP_VERSION installed (SHA-256 verified)"
