#!/usr/bin/env bash
# Builds the small, audio-only FFmpeg that Verbatim uses to read files AVFoundation can't (MKV, WebM, AVI, FLV,
# WMV, Ogg). Output: mac/Vendor/ffmpeg/
#   libavutil, libswresample, libavcodec, libavformat  .xcframework  (dynamic frameworks: macOS universal,
#                                                                     iOS device arm64, iOS simulator arm64 + x86_64)
#   include/                                                          (the C headers, the same for every slice)
#   COPYING.LGPLv2.1, BUILD_ID
#
# License: LGPL 2.1 or later. No --enable-gpl, no --enable-version3, no --enable-nonfree, no external libraries
# except the system zlib. The libraries are linked dynamically and embedded as separate frameworks, so anyone can
# rebuild them with this script (or their own changes) and replace them in the app. FFmpeg's source is the pinned
# tarball below; this script is the complete build recipe. The app quotes it in Verbatim/Resources/FFmpeg/FFmpeg-NOTICE.txt.
#
#   bash mac/ffmpeg/build.sh                     builds, or does nothing when the output matches this script
#   bash mac/ffmpeg/build.sh --print-configure   prints the configure options (for the notice in the app)
#
# Needs: Xcode (clang, lipo, xcodebuild), curl, shasum. Takes about 5–10 minutes. CI caches the output, keyed on
# this script's hash, so changing the version or any option here rebuilds it.
set -euo pipefail

FFMPEG_VERSION="7.1.5"
FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
MACOS_MIN="14.0"    # project.yml: deploymentTarget.macOS
IOS_MIN="17.0"      # project.yml: deploymentTarget.iOS
LIBS=(libavutil libswresample libavcodec libavformat)

CONFIGURE_FLAGS=(
  --disable-everything --disable-programs --disable-doc --disable-network --disable-autodetect
  --disable-debug --disable-asm --disable-avdevice --disable-avfilter --disable-swscale
  --enable-avformat --enable-avcodec --enable-swresample
  --enable-shared --disable-static --enable-pic --enable-small --enable-zlib
  --enable-protocol=file
  --enable-demuxer=matroska,mov,avi,flv,asf,ogg,mp3,wav,w64,aac,flac,mpegts,mpegps,amr
  --enable-decoder=aac,aac_latm,mp1,mp2,mp3,opus,vorbis,flac,ac3,eac3,alac,dca,wmav1,wmav2,wmapro,amrnb,amrwb,adpcm_ima_wav,adpcm_ms
  --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,pcm_s16le_planar,pcm_s24le_planar,pcm_s32le_planar,pcm_bluray,pcm_dvd
  --enable-parser=aac,aac_latm,mpegaudio,opus,vorbis,ac3,flac,dca,amr
)

if [ "${1:-}" = "--print-configure" ]; then echo "${CONFIGURE_FLAGS[*]}"; exit 0; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$(dirname "$HERE")"
OUT="$MAC/Vendor/ffmpeg"
NOTICE="$MAC/Verbatim/Resources/FFmpeg/FFmpeg-NOTICE.txt"
STAMP="$(shasum -a 256 "$HERE/build.sh" | cut -c1-16)"

# The notice in the app quotes the configure options; keep it honest.
if ! grep -qF -- "${CONFIGURE_FLAGS[*]}" "$NOTICE"; then
  echo "error: $NOTICE doesn't quote the configure options. Paste the output of --print-configure into it." >&2
  exit 1
fi

complete() {
  [ "$(cat "$OUT/BUILD_ID" 2>/dev/null)" = "$STAMP" ] || return 1
  for l in "${LIBS[@]}"; do [ -d "$OUT/$l.xcframework" ] || return 1; done
  [ -f "$OUT/include/libavformat/avformat.h" ]
}
if complete && [ "${FFMPEG_REBUILD:-0}" != "1" ]; then echo "FFmpeg $FFMPEG_VERSION is up to date ($STAMP)."; exit 0; fi

WORK="${FFMPEG_WORK:-${TMPDIR:-/tmp}/verbatim-ffmpeg}"
mkdir -p "$WORK"
TARBALL="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz"
if [ ! -f "$TARBALL" ] || ! echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "Downloading FFmpeg $FFMPEG_VERSION…"
  curl -fsSL --retry 3 -o "$TARBALL" "$FFMPEG_URL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - || { echo "error: FFmpeg tarball checksum mismatch" >&2; exit 1; }

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# build_slice <name> <sdk> <ffmpeg arch> <clang target>
build_slice() {
  local name="$1" sdk="$2" arch="$3" target="$4"
  local src="$WORK/src-$name" prefix="$WORK/out-$name"
  rm -rf "$src" "$prefix"; mkdir -p "$src"
  tar -xJf "$TARBALL" -C "$src" --strip-components 1
  local sysroot cc flags
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  flags="-target $target -isysroot $sysroot"
  echo "Building FFmpeg for $name ($target)…"
  (
    cd "$src"
    if ! ./configure --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch="$arch" \
         --cc="$cc" --sysroot="$sysroot" --install-name-dir=@rpath \
         --extra-cflags="$flags" --extra-ldflags="$flags -Wl,-headerpad_max_install_names" \
         "${CONFIGURE_FLAGS[@]}" > configure.out 2>&1; then
      tail -n 40 configure.out; tail -n 60 ffbuild/config.log; exit 1
    fi
    if ! make -j"$JOBS" > make.out 2>&1; then grep -E "error" make.out | head -n 20; tail -n 30 make.out; exit 1; fi
    make install > /dev/null 2>&1
  )
}

build_slice macos-arm64  macosx          aarch64 "arm64-apple-macos$MACOS_MIN"
build_slice macos-x86_64 macosx          x86_64  "x86_64-apple-macos$MACOS_MIN"
build_slice ios-arm64    iphoneos        aarch64 "arm64-apple-ios$IOS_MIN"
build_slice sim-arm64    iphonesimulator aarch64 "arm64-apple-ios$IOS_MIN-simulator"
build_slice sim-x86_64   iphonesimulator x86_64  "x86_64-apple-ios$IOS_MIN-simulator"

# The dylib a library installed as (libavformat.61.dylib), by name.
dylib() { ls "$WORK/out-$1/lib/$2".*.dylib | grep -E "/$2\.[0-9]+\.dylib$" | head -1; }

# make_framework <platform dir> <lib> <binary (thin or fat)> <macos|ios|sim>
make_framework() {
  local dir="$1" lib="$2" bin="$3" kind="$4"
  local fw="$dir/$lib.framework" exe plist id
  rm -rf "$fw"
  if [ "$kind" = macos ]; then
    mkdir -p "$fw/Versions/A/Resources"
    exe="$fw/Versions/A/$lib"; plist="$fw/Versions/A/Resources/Info.plist"; id="@rpath/$lib.framework/Versions/A/$lib"
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$lib" "$fw/$lib"
    ln -s Versions/Current/Resources "$fw/Resources"
  else
    mkdir -p "$fw"
    exe="$fw/$lib"; plist="$fw/Info.plist"; id="@rpath/$lib.framework/$lib"
  fi
  cp "$bin" "$exe"
  chmod 755 "$exe"
  strip -x "$exe" 2>/dev/null || true
  install_name_tool -id "$id" "$exe" 2>/dev/null
  # Point at the other libraries by their framework paths.
  otool -L "$exe" | awk 'NR>1 {print $1}' | grep -E '^@rpath/lib(avutil|swresample|avcodec|avformat)\.[0-9]+\.dylib$' | while read -r dep; do
    local d; d="$(basename "$dep" | cut -d. -f1)"
    local to="@rpath/$d.framework/$d"; [ "$kind" = macos ] && to="@rpath/$d.framework/Versions/A/$d"
    install_name_tool -change "$dep" "$to" "$exe" 2>/dev/null
  done
  local platform min minkey
  case "$kind" in
    macos) platform=MacOSX; min="$MACOS_MIN"; minkey=LSMinimumSystemVersion ;;
    ios)   platform=iPhoneOS; min="$IOS_MIN"; minkey=MinimumOSVersion ;;
    sim)   platform=iPhoneSimulator; min="$IOS_MIN"; minkey=MinimumOSVersion ;;
  esac
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$lib</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.$lib</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$lib</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
  <key>CFBundleVersion</key><string>$FFMPEG_VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>$minkey</key><string>$min</string>
</dict>
</plist>
PLIST
  # install_name_tool invalidates the linker's ad-hoc signature; Xcode re-signs with your identity when it embeds.
  codesign --force --sign - "$exe" >/dev/null 2>&1
}

STAGE="$WORK/frameworks"
rm -rf "$STAGE"; mkdir -p "$STAGE/macos" "$STAGE/ios" "$STAGE/sim"
rm -rf "$OUT"; mkdir -p "$OUT"
for l in "${LIBS[@]}"; do
  lipo -create "$(dylib macos-arm64 "$l")" "$(dylib macos-x86_64 "$l")" -output "$STAGE/$l-macos"
  lipo -create "$(dylib sim-arm64 "$l")" "$(dylib sim-x86_64 "$l")" -output "$STAGE/$l-sim"
  make_framework "$STAGE/macos" "$l" "$STAGE/$l-macos" macos
  make_framework "$STAGE/ios" "$l" "$(dylib ios-arm64 "$l")" ios
  make_framework "$STAGE/sim" "$l" "$STAGE/$l-sim" sim
  xcodebuild -create-xcframework -framework "$STAGE/macos/$l.framework" -framework "$STAGE/ios/$l.framework" \
    -framework "$STAGE/sim/$l.framework" -output "$OUT/$l.xcframework" > /dev/null
done
cp -R "$WORK/out-macos-arm64/include" "$OUT/include"
cp "$WORK/src-macos-arm64/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
echo "$STAMP" > "$OUT/BUILD_ID"

echo "FFmpeg $FFMPEG_VERSION built into $OUT"
for kind in macos ios sim; do
  echo "  $kind: $(du -sch "$STAGE/$kind"/*.framework | tail -1 | cut -f1) (" \
    "$(for l in "${LIBS[@]}"; do printf '%s %s ' "$l" "$(du -sh "$STAGE/$kind/$l.framework" | cut -f1)"; done))"
done
