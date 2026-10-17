#!/usr/bin/env bash
# Generates the synthetic bench clips (16 kHz mono WAV + reference .txt) with macOS `say`.
# Usage: bash Bench/make-clips.sh <out-dir> [--fixtures path/to/clips.json]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ $# -lt 1 ]; then echo "usage: $0 <out-dir> [--fixtures clips.json]" >&2; exit 2; fi
exec python3 -I "$here/make_clips.py" "$@"
