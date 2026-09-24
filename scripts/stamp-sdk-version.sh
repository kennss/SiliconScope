#!/usr/bin/env bash
#
#  File:      stamp-sdk-version.sh
#  Created:   2026-09-24
#  Updated:   2026-09-24
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Makes a Mach-O executable's LC_BUILD_VERSION record the SDK it was actually built
#             against. Run on every shipped binary BEFORE it is signed (the edit invalidates a
#             signature). Does nothing when the recorded SDK is already right.
#  Notes:     Why this exists. Xcode 27's SwiftPM builds through the new swift-build backend, which
#             links by calling swiftc directly without SDKROOT in the environment — and the Swift 6.4
#             driver takes the linker's SDK version from SDKROOT, not from -sdk. The link then records
#             the DEPLOYMENT TARGET as the SDK ("minos 14.0 sdk 14.0"), although every object in it was
#             compiled against the 27.0 SDK. macOS decides "linked on or after" behaviour from that
#             field, so the app ran as a macOS 14-era binary: legacy window chrome (a grey title bar
#             instead of the transparent one, no glass toolbar buttons) and every newer SDK behaviour
#             switched off. Reproduced with a one-line Swift file: swiftc without SDKROOT → sdk 14.0,
#             with it → 27.0. The backend strips SDKROOT from its tasks, so exporting it does not help.
#
#             The fix restates a fact rather than inventing one: the SDK is `xcrun --show-sdk-version`,
#             the same SDK the objects already carry; the minimum version is kept as the binary has it.
#             Once the toolchain records it correctly, the check below finds nothing to do.
#
#  Usage:     scripts/stamp-sdk-version.sh <binary> [<binary> …]
#
set -euo pipefail

SDK="$(xcrun --show-sdk-version)"

for BIN in "$@"; do
  # Every architecture's (minos, sdk) pair; a universal binary carries one per slice.
  PAIRS="$(otool -arch all -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{m=$2} f&&/ sdk /{print m, $2; f=0}' | sort -u)"
  if [ -z "$PAIRS" ]; then
    echo "✗ $BIN: no LC_BUILD_VERSION found" >&2; exit 1
  fi
  if [ "$(echo "$PAIRS" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')" != "1" ]; then
    echo "✗ $BIN: slices disagree on the minimum version ($PAIRS) — not guessing which to keep" >&2; exit 1
  fi
  MINOS="$(echo "$PAIRS" | awk 'NR==1{print $1}')"
  RECORDED="$(echo "$PAIRS" | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"

  if [ "$RECORDED" = "$SDK" ]; then
    echo "✓ $(basename "$BIN"): SDK $SDK already recorded"
    continue
  fi

  xcrun vtool -set-build-version macos "$MINOS" "$SDK" -replace -output "$BIN" "$BIN"
  AFTER="$(otool -arch all -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; f=0}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  if [ "$AFTER" != "$SDK" ]; then
    echo "✗ $BIN: SDK still reads '$AFTER' after the stamp (wanted $SDK)" >&2; exit 1
  fi
  echo "✓ $(basename "$BIN"): SDK $RECORDED → $SDK (minimum stays $MINOS)"
done
