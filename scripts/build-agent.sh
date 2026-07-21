#!/usr/bin/env bash
#
#  File:      build-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-07-22
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Cross-compiles the SiliconScope fleet agent (agent/) into static, dependency-free
#             single binaries for Linux amd64 + arm64 — the download targets for install-agent.sh
#             and the assets to attach to a GitHub release. Pure-Go (CGO disabled), so the target
#             box needs no Go toolchain, libc, or shared libraries.
#  Notes:     Output: dist/agent/sscope-agent-linux-<arch>. Version comes from `agentVersion` in
#             agent/main.go (read via `--version`). -trimpath + "-s -w" strip paths/symbols for a
#             smaller, reproducible binary. Run from anywhere (cd's to repo root).
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="dist/agent"
mkdir -p "$OUT"

VERSION="$(cd agent && go run . --version)"
echo "▸ Building sscope-agent $VERSION (static, CGO_ENABLED=0)…"

for arch in amd64 arm64; do
  echo "  - linux/$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C agent build -trimpath -ldflags="-s -w" -o "../$OUT/sscope-agent-linux-$arch" .
done

echo "✓ Binaries in $OUT:"
ls -lh "$OUT"/sscope-agent-linux-* 2>/dev/null || true
