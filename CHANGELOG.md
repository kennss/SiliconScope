# Changelog

## Unreleased

AI-workload monitoring — the next-version hero feature.

- **AI Workload view** — a bottleneck classifier with a single verdict:
  bandwidth-bound / compute-bound / thermal-throttled / memory-pressured (plus idle /
  GPU-active). Front-and-center hero card on the dashboard; mirrored as a `Workload:`
  line in the menu bar.
- **Per-chip memory-bandwidth ceiling table** + a "% of ceiling" gauge (M1–M4; Max bins
  split by P-core count; self-corrects to the observed peak for chips outside the table).
- **GPU throttle detector** — flags the GPU clock held below its slowly-decaying rolling
  peak while thermal pressure has risen (warning banner + menu-bar flame).
- **Compact GPU menu-bar mode** — single line: GPU% / GPU W / GPU GB/s / die °C.

## v1.0.2 — 2026-06-09

Crash fix: launch failure on macOS 27.

- Fixed an immediate crash on launch under macOS 26/27 (`EXC_BREAKPOINT` in
  `Bundle.module`). The SwiftPM resource bundle is a flat folder with no
  `Info.plist`; macOS 27's stricter bundle validation rejects it, so SwiftPM's
  generated `Bundle.module` accessor hit its `fatalError`.
- The app icon is now resolved via the main bundle (with a dev-run fallback),
  removing all dependence on `Bundle.module`. Thanks to @colaH16 (#1).

## v1.0.1 — 2026-06-09

Bug fix: memory-bandwidth Media Engine reporting.

- Fixed Media Engine bandwidth reading 0 while a media-engine app (e.g. video
  transcoding) was active — now classifies the real channels (VENC / VDEC /
  ISP / JPEG / STRM CODEC / ProRes), matching NeoAsitop.
- `MSR` is no longer miscounted as Media; it now falls into Other.
- Total bandwidth now uses the chip-wide `DCS` aggregate, with Other derived as
  total − CPU − GPU − Media, so the parts sum to the real total (previously
  double-counted, ~104 vs ~50 GB/s).

## v1.0.0 — 2026-06-09

First public release. A sudoless Apple Silicon system monitor with a native SwiftUI GUI.

- CPU E-core / P-core usage (tick-based, Activity-Monitor-accurate) + per-cluster frequency
- GPU utilization / power / frequency; ANE power; Media Engine bandwidth
- Memory: Wired / Active / Compressed / Free stacked bar + macOS memory-pressure alerts
- Memory bandwidth: CPU / GPU / Media / total
- Network ↑/↓ and Disk read/write + free capacity, with live graphs
- Temperatures grouped CPU / GPU / Memory / Battery (SMC, per-core folded), fans, thermal pressure
- Per-domain power (CPU/GPU/ANE/DRAM/SoC), battery %
- Processes: sort / filter / kill, in-card scroll
- Menu-bar mode + full dashboard; settings (refresh interval, °C/°F)
- App icon + bar-motif menu-bar glyph
