#!/usr/bin/env bash
# Builds libharper_ffi.a for iPhone (device) and the iOS simulator from mac/harper-ffi.
# Needs rustup targets aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios.
set -euo pipefail
cd "$(dirname "$0")/../../harper-ffi"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
quiet() { grep -v "^\s*\(Compiling\|Downloaded\|Updating\|Downloading\|Locking\|Adding\)" || true; }
cargo build -q --release --target aarch64-apple-ios 2>&1 | quiet
cargo build -q --release --target aarch64-apple-ios-sim 2>&1 | quiet
cargo build -q --release --target x86_64-apple-ios 2>&1 | quiet
mkdir -p ../Vendor/harper/ios ../Vendor/harper/ios-sim
cp target/aarch64-apple-ios/release/libharper_ffi.a ../Vendor/harper/ios/libharper_ffi.a
lipo -create target/aarch64-apple-ios-sim/release/libharper_ffi.a target/x86_64-apple-ios/release/libharper_ffi.a -output ../Vendor/harper/ios-sim/libharper_ffi.a
echo "built iOS $(du -h ../Vendor/harper/ios/libharper_ffi.a | cut -f1), simulator $(du -h ../Vendor/harper/ios-sim/libharper_ffi.a | cut -f1)"
