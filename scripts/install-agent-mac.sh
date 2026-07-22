#!/bin/sh
#
#  File:      install-agent-mac.sh
#  Created:   2026-07-22
#  Updated:   2026-07-22
#  Developer: Kennt Kim / Calida Lab
#  Overview:  One-line installer for the headless SiliconScope Mac agent (sscope-agent-mac). Fetches
#             the universal binary from the latest GitHub release, installs it to /usr/local/bin, and
#             registers a LaunchAgent that serves this Mac's metrics on :7799 over TLS + mDNS. Prints
#             a one-time pairing token to enter on another Mac. For headless Mac minis / Studios; on a
#             Mac you actually use, the app's Settings → "Share this Mac" toggle is simpler.
#  Notes:     POSIX sh. LaunchAgent (per-user session) — for a truly login-less box, load it as a
#             LaunchDaemon instead. Overrides: SSCOPE_PORT (7799), SSCOPE_REPO (kennss/SiliconScope),
#             SSCOPE_LOCAL_BIN (install a local binary — release-less testing / offline).
#
set -eu

REPO="${SSCOPE_REPO:-kennss/SiliconScope}"
BIN="/usr/local/bin/sscope-agent-mac"
PORT="${SSCOPE_PORT:-7799}"
LABEL="ai.calidalab.sscope-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname -s)" = "Darwin" ] || { echo "This installer is for macOS. Use install-agent.sh on Linux."; exit 1; }
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# --- obtain the binary (local file or latest release) ---
if [ -n "${SSCOPE_LOCAL_BIN:-}" ]; then
  echo "▸ Installing local binary: $SSCOPE_LOCAL_BIN"
  $SUDO install -m 0755 "$SSCOPE_LOCAL_BIN" "$BIN"
else
  URL="https://github.com/$REPO/releases/latest/download/sscope-agent-mac"
  echo "▸ Downloading sscope-agent-mac (universal) from $URL …"
  tmp="$(mktemp)"
  curl -fsSL "$URL" -o "$tmp"
  $SUDO install -m 0755 "$tmp" "$BIN"
  rm -f "$tmp"
fi
echo "  installed: $BIN ($("$BIN" --version))"

# --- LaunchAgent (auto-start, restart on crash) ---
echo "▸ Registering LaunchAgent (port: $PORT)…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--serve</string>
    <string>:$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/tmp/sscope-agent-mac.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "✓ sscope-agent-mac is running on :$PORT and will auto-start at login."
sleep 1
echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Pairing token — enter it in SiliconScope → Fleet on another Mac:"
echo
echo "      $("$BIN" --print-token)"
echo
echo "  This Mac then appears in that Mac's Fleet sidebar, encrypted."
echo "──────────────────────────────────────────────────────────────────"
