#!/usr/bin/env bash
#
#  File:      build-mac-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-07-22
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Builds the headless Mac fleet agent (sscope-agent-mac) as a universal (arm64 + x86_64)
#             release binary — the download target for install-agent-mac.sh and the asset to attach
#             to a GitHub release. Uses xcrun so it links against the Xcode SDK (the swiftly default
#             toolchain can't find the macOS SDK).
#  Notes:     Output: dist/agent/sscope-agent-mac. For distribution, Developer ID–sign + notarize it
#             separately (same identity as the app). Requires the IOReport dynamic_lookup flag, which
#             the target already carries in Package.swift.
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="dist/agent"
mkdir -p "$OUT"

echo "▸ Building sscope-agent-mac (universal arm64 + x86_64, release)…"
xcrun swift build -c release --arch arm64 --arch x86_64 --product sscope-agent-mac

BIN=".build/apple/Products/Release/sscope-agent-mac"
cp "$BIN" "$OUT/sscope-agent-mac"

echo "✓ $OUT/sscope-agent-mac"
lipo -info "$OUT/sscope-agent-mac" 2>/dev/null || file "$OUT/sscope-agent-mac"
