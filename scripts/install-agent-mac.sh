#!/bin/sh
#
#  File:      install-agent-mac.sh
#  Created:   2026-07-22
#  Updated:   2026-07-24
#  Developer: Kennt Kim / Calida Lab
#  Overview:  One-line installer for the headless SiliconScope Mac agent (sscope-agent-mac). Fetches
#             the universal binary from the latest GitHub release, installs it under the user's own
#             ~/.local/bin, and registers a LaunchAgent that serves this Mac's metrics on :7799 over
#             TLS + mDNS. Ends by printing ONE pairing link to paste into another Mac's SiliconScope
#             ("Add machine…"). For headless Mac minis / Studios; on a Mac you actually use, the
#             app's Settings → "Share this Mac" toggle is simpler.
#  Notes:     POSIX sh. NO SUDO by default: a LaunchAgent runs in the user's own session, so root
#             buys nothing — which also lets `ssh box 'curl … | sh'` finish unattended. Set
#             SSCOPE_BIN=/usr/local/bin/sscope-agent-mac for a system-wide install; the script
#             escalates only when the chosen directory isn't writable. Other overrides: SSCOPE_PORT
#             (7799), SSCOPE_REPO (kennss/SiliconScope), SSCOPE_LOCAL_BIN (install a local binary —
#             release-less testing / offline). LaunchAgent = per-user session; for a truly login-less
#             box, load it as a LaunchDaemon instead. Re-installs unload the agent BEFORE replacing
#             the binary — overwriting a live executable aborts the running process.
#
set -eu

REPO="${SSCOPE_REPO:-kennss/SiliconScope}"
BIN="${SSCOPE_BIN:-$HOME/.local/bin/sscope-agent-mac}"
PORT="${SSCOPE_PORT:-7799}"
LABEL="ai.calidalab.sscope-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname -s)" = "Darwin" ] || { echo "This installer is for macOS. Use install-agent.sh on Linux."; exit 1; }

# --- uninstall: stop + unregister the agent and remove everything it created (issue #34) ---
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  echo "▸ Removing the SiliconScope Mac agent…"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  rm -f "$BIN"
  # Token + self-signed cert + the private keychain that prompted for a password.
  rm -rf "$HOME/Library/Application Support/SiliconScope/agent"
  rm -f /tmp/sscope-agent-mac.log
  echo "✓ Uninstalled. (The SiliconScope app, if installed, is untouched.)"
  echo "  On the viewer Mac, right-click this machine in the Fleet sidebar → Remove machine."
  exit 0
fi

# Escalate only when the chosen directory isn't ours (i.e. the caller opted into a system path).
BINDIR="$(dirname "$BIN")"
mkdir -p "$BINDIR" 2>/dev/null || true
if [ -w "$BINDIR" ]; then SUDO=""; else SUDO="sudo"; fi

# --- stop any running agent BEFORE swapping its binary (overwriting a live executable aborts it) ---
launchctl unload "$PLIST" 2>/dev/null || true

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

launchctl load "$PLIST"

echo "✓ sscope-agent-mac is running on :$PORT and will auto-start at login."
sleep 1
echo
echo "──────────────────────────────────────────────────────────────────"
echo "  Paste this ONE line into SiliconScope → Add machine… on your Mac:"
echo
echo "      $("$BIN" --pair-url --serve ":$PORT")"
echo
echo "  It carries this Mac's name, address and pairing token — one paste"
echo "  and it joins your Fleet, encrypted. (Over Tailscale/VPN, swap the"
echo "  host for that network's address.)"
echo "──────────────────────────────────────────────────────────────────"
