#!/bin/sh
#
#  File:      install-agent.sh
#  Created:   2026-07-22
#  Updated:   2026-07-24
#  Developer: Kennt Kim / Calida Lab
#  Overview:  THE install entry point for the SiliconScope fleet agent — one URL for every platform.
#             On macOS it hands off to install-agent-mac.sh; on Linux it detects the CPU arch, fetches
#             the matching static binary from the latest GitHub release, installs it to /usr/local/bin,
#             and registers a hardened systemd service serving token-protected metrics over TLS on
#             :7799 + mDNS. It ends by printing ONE pairing link to paste into the Mac app's
#             "Add machine…" — name, address and token in a single copy.
#             Intended for:  curl -fsSL <raw-url>/install-agent.sh | sh
#             Uninstall:     download it and run  sh install-agent.sh --uninstall
#  Notes:     POSIX sh (no bashisms) for maximum portability. Uses sudo only when not already root —
#             a systemd SYSTEM service must start at boot without a login session, so root is real
#             here (unlike the Mac agent, whose LaunchAgent needs none).
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

# --- platform dispatch: this is THE install URL for every platform ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "▸ macOS detected — handing off to the Mac agent installer…"
  exec sh -c "curl -fsSL 'https://raw.githubusercontent.com/$REPO/main/scripts/install-agent-mac.sh' | sh"
fi

# --- platform detection ---
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
[ "$os" = "linux" ] || { echo "This installer supports Linux and macOS (got: $os)."; exit 1; }
case "$(uname -m)" in
  x86_64|amd64)  arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "Unsupported CPU arch: $(uname -m)"; exit 1 ;;
esac

# --- privilege + service identity ---
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# --- uninstall: stop + disable the service and remove everything it created ---
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  echo "▸ Removing the SiliconScope fleet agent…"
  $SUDO systemctl disable --now sscope-agent 2>/dev/null || true
  $SUDO rm -f "$SERVICE" "$BIN"
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO rm -rf /var/lib/sscope-agent   # token + self-signed TLS cert
  echo "✓ Uninstalled."
  echo "  On the viewer Mac, right-click this machine in the Fleet sidebar → Forget pairing."
  exit 0
fi
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
TOKEN="$($SUDO cat "$TOKEN_FILE" 2>/dev/null || true)"
# A reachable address for the viewer: the route-selected source IP, else the first configured one.
IP="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
[ -n "$IP" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="$(hostname)"
echo "──────────────────────────────────────────────────────────────────"
if [ -n "$TOKEN" ]; then
  echo "  Paste this ONE line into SiliconScope → Add machine… on your Mac:"
  echo
  echo "      sscope://pair?name=$(hostname)&host=$IP&port=$PORT&token=$TOKEN"
  echo
  echo "  It carries this box's name, address and pairing token — one paste"
  echo "  and it joins your Fleet, encrypted. (Over Tailscale/VPN, swap the"
  echo "  host for that network's address.)"
else
  echo "  Pairing token (read it with: sudo cat $TOKEN_FILE)"
fi
echo "──────────────────────────────────────────────────────────────────"
