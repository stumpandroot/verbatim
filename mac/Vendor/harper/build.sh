#!/usr/bin/env bash
# Builds libharper_ffi.a (universal) from mac/harper-ffi. Needs rustup targets aarch64-apple-darwin and x86_64-apple-darwin.
set -euo pipefail
cd "$(dirname "$0")/../../harper-ffi"
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin
lipo -create target/aarch64-apple-darwin/release/libharper_ffi.a target/x86_64-apple-darwin/release/libharper_ffi.a -output ../Vendor/harper/libharper_ffi.a
echo "built $(du -h ../Vendor/harper/libharper_ffi.a | cut -f1)"
