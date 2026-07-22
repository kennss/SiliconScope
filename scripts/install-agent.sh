#!/bin/sh
#
#  File:      install-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-07-22
#  Developer: Kennt Kim / Calida Lab
#  Overview:  One-line installer for the SiliconScope fleet agent on a Linux box. Detects the CPU
#             arch, fetches the matching static binary from the latest GitHub release, installs it
#             to /usr/local/bin, and registers a hardened systemd service that serves token-protected
#             metrics over TLS on :7799 and advertises over mDNS. It prints a one-time pairing token
#             to enter on the Mac; the machine then appears in the Fleet view automatically,
#             encrypted. Intended for:  curl -fsSL <raw-url>/install-agent.sh | sh
#  Notes:     POSIX sh (no bashisms) for maximum portability. Uses sudo only when not already root.
#             Overrides (env): SSCOPE_PORT (default 7799), SSCOPE_REPO (default kennss/SiliconScope),
#             SSCOPE_LOCAL_BIN (install a local binary instead of downloading — for release-less
#             testing and offline/air-gapped installs). The service runs as the invoking user so
#             nvidia-smi and a user-run Ollama are reachable.
#
set -eu

REPO="${SSCOPE_REPO:-kennss/SiliconScope}"
BIN="/usr/local/bin/sscope-agent"
PORT="${SSCOPE_PORT:-7799}"
SERVICE="/etc/systemd/system/sscope-agent.service"

# --- platform detection ---
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
[ "$os" = "linux" ] || { echo "This installer supports Linux only (got: $os)."; exit 1; }
case "$(uname -m)" in
  x86_64|amd64)  arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "Unsupported CPU arch: $(uname -m)"; exit 1 ;;
esac

# --- privilege + service identity ---
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
RUN_USER="${SUDO_USER:-$(id -un)}"

# --- obtain the binary (local file or latest release) ---
if [ -n "${SSCOPE_LOCAL_BIN:-}" ]; then
  echo "▸ Installing local binary: $SSCOPE_LOCAL_BIN"
  $SUDO install -m 0755 "$SSCOPE_LOCAL_BIN" "$BIN"
else
  URL="https://github.com/$REPO/releases/latest/download/sscope-agent-$os-$arch"
  echo "▸ Downloading sscope-agent ($os/$arch) from $URL …"
  tmp="$(mktemp)"
  curl -fsSL "$URL" -o "$tmp"
  $SUDO install -m 0755 "$tmp" "$BIN"
  rm -f "$tmp"
fi
echo "  installed: $BIN ($("$BIN" --version))"

# --- systemd service (auto-start on boot, restart on crash) ---
echo "▸ Registering systemd service (user: $RUN_USER, port: $PORT)…"
$SUDO tee "$SERVICE" >/dev/null <<UNIT
[Unit]
Description=SiliconScope Fleet Agent
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
ExecStart=$BIN --serve :$PORT
Restart=on-failure
RestartSec=5
# Token + self-signed TLS cert live here; systemd creates /var/lib/sscope-agent (writable under strict).
StateDirectory=sscope-agent
# Hardening: the agent otherwise only reads /proc and shells out to nvidia-smi.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

$SUDO systemctl daemon-reload
$SUDO systemctl enable sscope-agent >/dev/null 2>&1 || true
$SUDO systemctl restart sscope-agent   # restart (not just start) so re-installs pick up the new binary

echo "✓ sscope-agent is running on :$PORT (TLS) and will auto-start on boot."
$SUDO systemctl --no-pager --lines=0 status sscope-agent || true

# Show the pairing token (the service generated it on first start) to enter on the Mac.
sleep 1
TOKEN_FILE="/var/lib/sscope-agent/token"
echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Pairing token — enter it in SiliconScope → Fleet on your Mac:"
echo
echo "      $($SUDO cat "$TOKEN_FILE" 2>/dev/null || echo '(run: sudo cat '"$TOKEN_FILE"')')"
echo
echo "  This machine then appears in the SiliconScope sidebar under Fleet, encrypted."
echo "──────────────────────────────────────────────────────────────────"
