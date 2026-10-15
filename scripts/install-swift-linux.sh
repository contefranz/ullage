#!/usr/bin/env bash
# Install a Swift 6.0 toolchain on x86_64 Linux for building/testing OrbitCore.
# Uses the SwiftWasm release on GitHub, which ships a full Linux host
# toolchain (swift build / swift test / XCTest), because download.swift.org
# is often not on cloud network allowlists.
set -euo pipefail
DEST=${1:-/opt/swift}
VER=swift-wasm-6.0.2-RELEASE
URL="https://github.com/swiftwasm/swift/releases/download/${VER}/${VER}-ubuntu22.04_x86_64.tar.gz"
if [ -x "$DEST/usr/bin/swift" ]; then echo "Swift already installed in $DEST"; exit 0; fi
TMP=$(mktemp -d)
curl -fsSL "$URL" -o "$TMP/swift.tgz"
mkdir -p "$DEST"
tar xzf "$TMP/swift.tgz" -C "$DEST" --strip-components=1
rm -rf "$TMP"
"$DEST/usr/bin/swift" --version
echo "Add to PATH: export PATH=$DEST/usr/bin:\$PATH"
