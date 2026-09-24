#!/usr/bin/env bash
#
#  File:      build-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-09-24
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Cross-compiles the SiliconScope fleet agent (agent/) into static, dependency-free
#             single binaries for Linux amd64 + arm64 — the download targets for install-agent.sh
#             and the assets to attach to a GitHub release. Pure-Go (CGO disabled), so the target
#             box needs no Go toolchain, libc, or shared libraries.
#  Notes:     Output: dist/agent/sscope-agent-linux-<arch>. Version comes from `agentVersion` in
#             agent/main.go (read from the source). -trimpath + "-s -w" strip paths/symbols for a
#             smaller, reproducible binary. Run from anywhere (cd's to repo root).
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="dist/agent"
mkdir -p "$OUT"

# Read from the source, not `go run . --version`: the readers are build-tagged for Linux and
# Windows (metrics_linux.go / metrics_windows.go), so the package does not build for the macOS
# host this script runs on.
VERSION="$(sed -n 's/^const agentVersion = "\(.*\)"$/\1/p' agent/main.go)"
[ -n "$VERSION" ] || { echo "✗ agentVersion not found in agent/main.go" >&2; exit 1; }
echo "▸ Building sscope-agent $VERSION (static, CGO_ENABLED=0)…"

for arch in amd64 arm64; do
  echo "  - linux/$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go -C agent build -trimpath -ldflags="-s -w" -o "../$OUT/sscope-agent-linux-$arch" .
done

echo "✓ Binaries in $OUT:"
ls -lh "$OUT"/sscope-agent-linux-* 2>/dev/null || true
