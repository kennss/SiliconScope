#!/usr/bin/env bash
#
#  File:      build-mac-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-09-24
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

# ⚠️ Ask SwiftPM where the universal binary is. This used to be a fixed ".build/apple/…" path — the
# old build backend's folder. Under Xcode 27's backend the build lands elsewhere, the old folder
# keeps whatever it last held, and the script copied a stale agent (14 Sep, v1.1.0) while reporting
# success: the v4.1.2 "wrong agent asset" failure, one release away from repeating.
BIN="$(xcrun swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/sscope-agent-mac"
cp "$BIN" "$OUT/sscope-agent-mac"
scripts/stamp-sdk-version.sh "$OUT/sscope-agent-mac"

# Prove what was produced instead of trusting the path: both slices, and the version this source says.
ARCHS="$(lipo -archs "$OUT/sscope-agent-mac")"
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "✗ not universal: $ARCHS" >&2; exit 1;; esac
WANT="$(sed -n 's/^private let agentVersion = "\(.*\)"/\1/p' Sources/sscope-agent-mac/main.swift)"
GOT="$("$OUT/sscope-agent-mac" --version)"
[ "$GOT" = "$WANT" ] || { echo "✗ built agent reports $GOT, source says $WANT — stale binary?" >&2; exit 1; }

echo "✓ $OUT/sscope-agent-mac ($GOT, $ARCHS)"
