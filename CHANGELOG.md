# Changelog

## v2.2.1 — 2026-06-21

Menu-bar polish — thanks to first-time contributor [@davidarny](https://github.com/davidarny)
for three of these fixes.

- **Unified popover buttons** — the combined and per-metric popovers now share one button style
  (rounded panel, hairline border, monospaced label, uniform height), with Open Dashboard as the
  single accent action. (#7)
- **Settings opens focused** — opening Settings from the popover now brings the app forward
  instead of leaving the window behind and greyed-out until a Cmd+Tab. (#8)
- **App icon sized to Apple's grid** — the Dock icon was full-bleed and read oversized next to
  stock apps; it's now inset (~100px margin) to match its neighbors. (#9)
- **Menu-bar dropdowns are mutually exclusive** — opening one SiliconScope dropdown now dismisses
  the others (the per-metric popovers and the combined SS popover) instead of stacking up, like
  every other menu-bar item.
- Dev: `scripts/build-app.sh` now embeds Sparkle.framework so the locally-built bundle launches.

## v2.2.0 — 2026-06-21

**GPU memory + an AI-cockpit cleanup.**

- **GPU unified-memory footprint** — the GPU / Media / Neural card and dropdown now show how
  much memory the GPU is actively using ("X.X GB in use"), read sudolessly from IOAccelerator.
  Apple Silicon shares one memory pool with no hard CPU/GPU split, but this surfaces the GPU's
  own footprint — something Activity Monitor and the TUI monitors don't show. It renders as a
  meter bar in its own sky-cyan color alongside GPU / ANE / Media, and as a fourth line in the
  overlaid 60-second history graph.
- **AI cockpit, side by side** — the AI Workload and AI Runtime cards now share one row
  (matching the rest of the 2-column grid) instead of being stacked, tightening the dashboard.
- **Denser, calmer layout** — every menu-bar dropdown and the dashboard cards were tightened
  to iStat-level row spacing.
- **Card graphs realigned** — each card's history graph is now pinned to the card's bottom
  edge, so graphs line up across a row regardless of how many bars sit above them and never
  spill past the card (fixes a graph-overflow bug). The dense Memory column dropped its cramped
  sparkline; Bandwidth keeps its graph.

## v2.1.3 — 2026-06-21

Discoverability: a **Menu bar items** section in Settings lets you toggle CPU / GPU / Memory /
Network / SSD / Sensors / Battery as individual menu-bar items — the same controls as the ⬚
pin on each dashboard card, now easy to find (the per-card pin stayed too subtle to discover).

## v2.1.2 — 2026-06-21

Added the **M5 generation** to the memory-bandwidth ceiling table — M5 153 / M5 Pro 307 /
M5 Max 614 GB/s — so M5 Macs show an accurate "% of ceiling" gauge instead of falling back to
the observed peak. (M5 Max's binned 32-core-GPU variant shares the same CPU config, so it uses
the full 614 with the observed-peak fallback covering the gap.) M1–M4 values verified unchanged.

## v2.1.1 — 2026-06-21

Fix: per-metric menu-bar glyphs picked their ink from the app's light/dark **mode** instead
of the menu bar's actual background — so the text was invisible on a dark menu bar while the
app was in Light Mode (a dark wallpaper, or a fullscreen app). Ink now follows each status
item's own appearance, so it matches the system clock/battery in every case. Thanks to the
community bug report. 🙏

## v2.1.0 — 2026-06-20

Memory deep-dive (iStat/Activity-Monitor parity) + project hardening. First release delivered
over the air via the v2.0 auto-updater.

- **Memory PRESSURE** — the MEM card and dropdown now show memory pressure as a percentage
  (`(wired + compressed) / total`, the figure Activity Monitor / iStat display) with a colored
  bar driven by the *kernel* pressure level (green/yellow/red — stays honest when the % is low
  but the kernel reports critical), plus the **App Memory** / **Cached Files** breakdown.
- **Memory PAGES** — the MEM dropdown adds live VM page rates (Page-ins, Page-outs, Swap-ins,
  Swap-outs per second); Swap-outs turn red when nonzero (eviction under real pressure).
- **Tested sampling math** — extracted the pure logic from hardware-coupled samplers and added
  deterministic tests (13 → 47): the bottleneck classifier + per-chip bandwidth table, memory
  fractions/budget, sensor classification, the bandwidth requestor map, and battery health.
- **Contributing** — `sscope-cli --sensors` dumps the curated SMC keys (read/absent) + raw HID
  set for verifying per-chip temperature tables, with a CONTRIBUTING.md guide. **M2–M5 owners
  welcome.**
- **Security** — added SECURITY.md (read-only / sudoless / no-egress posture) + private
  vulnerability reporting.

## v2.0.0 — 2026-06-20

SiliconScope grows from an AI/SoC dashboard into a **full menu-bar system monitor** — a
daily driver that can stand in for iStat Menus, still 100% sudoless.

### Menu bar — every metric, its own item
- **Per-metric menu-bar items**: pin **CPU / GPU / Memory / Network / SSD / Sensors / Battery**
  each to its own menu-bar glyph + rich dropdown (alongside the combined "SS" cockpit glyph).
  Toggled from each dashboard card; implemented with AppKit `NSStatusItem` + `NSPopover`.
- **iStat-style glyphs**: fixed-width readouts that don't jiggle the menu bar; CPU shows E/P
  bars, GPU shows GPU/Media/ANE bars; decimal (Finder) units so disk matches iStat.
- **iStat-style dropdowns**: per-volume Disks (+ network disks), interfaces with IPv4, a
  Memory stacked bar with swap + top-by-memory, and per-engine 60s trends.

### Per-unit temperatures (curated)
- Reads **real per-unit sensors** — **E-Core / P-Core / GPU / Memory** — via curated
  per-generation SMC FourCC key tables (**M1–M5**, adapted from Stats, MIT), read directly.
  Falls back to the HID sensor set (`IOHIDEventSystem`) on chips without a table, then an SMC
  scan on Intel. (Curated tables validated on M1 Max; other generations are best-effort + HID.)

### Battery
- **Health %, cycle count, condition** read from AppleSmartBattery (IORegistry), plus a
  dropdown with the SoC power breakdown and the energy-hungry apps.
- **Stateful upright battery glyph**: a bolt while charging, a plug while on AC but not
  charging, red fill at/under 20% on battery.

### Dashboard
- CPU and GPU cards now show **overlaid multi-series trends** (E+P, and GPU/Media/ANE) with
  colors shared across glyph, dropdown, and dashboard. The redundant DRAM-power line is gone.

### Auto-update
- Built-in **Sparkle** updater (EdDSA-signed, GitHub-Releases appcast). "Check for Updates…"
  in the app menu, the menu-bar dropdown, and Settings (with an automatic-check toggle).
  This is the last DMG you download by hand.

## v1.8.0 — 2026-06-19

iStat-style per-metric menu-bar items — promote any card to its own menu-bar readout.

- **Per-metric menu-bar items** — each dashboard card (CPU / GPU / MEM / NET / SSD) has a
  small pin toggle that promotes that metric to its own item in the menu bar, with a live
  glyph and a rich dropdown. The combined "SS" glyph stays on by default; the rest are opt-in.
  (Implemented with AppKit `NSStatusItem` + `NSPopover`: SwiftUI's `MenuBarExtra` can't toggle
  scenes dynamically, and `isInserted:` triggers a main-menu update loop.)
- **Glyphs** — CPU shows thick E/P bars (amber/blue); GPU shows GPU/Media/ANE bars
  (green/orange/purple); MEM/NET/SSD show a stacked label + two-line readout. Each is drawn to
  a bitmap and adapts to the menu-bar appearance (light/dark).
- **Fixed width** — the two-line glyphs reserve a worst-case value column and right-align the
  number, so the menu bar no longer jiggles as values change width.
- **iStat-style dropdowns** — CPU (E/P cores, temp, load avg, uptime, top processes); GPU/Media/ANE
  meters + 60s history; MEM (Wired/Active/Compressed/Free stacked bar, swap, top by memory);
  SSD (per-volume usage, network disks, R/W activity); NET (interfaces with IPv4, ↓/↑ + peak).
- **Honest, local-only** — readouts use the decimal (Finder) convention so disk values match
  iStat (576 GB, not 536 GiB). No public-IP lookup and no per-process network (both would need
  an outbound call / privilege — against the "nothing leaves your Mac" stance).
- **Fix — per-process CPU%.** `proc_taskinfo` CPU times are mach ticks, not nanoseconds; they
  were used raw, so every process read ~42× too low on Apple Silicon. Now converted via
  `mach_timebase_info`, matching Activity Monitor / iStat.

## v1.7.0 — 2026-06-19

Daily-driver basics.

- **Launch at login** — opt-in in Settings (SMAppService; no helper bundle, no login-item plist).
- **Alert notifications** — opt-in macOS notifications when the GPU thermal-throttles, memory
  pressure goes critical, or the machine starts swapping. Edge-triggered (once per event) with
  a 5-minute per-condition cooldown so a flapping signal can't spam.

## v1.6.0 — 2026-06-19

Rapid-MLX support + a runtime-detection fix.

- **Rapid-MLX runtime** — detected like any other engine (🐇), with its loaded model read
  from the OpenAI-compatible API (`:8000`) and the **"Measure tok/s"** benchmark working out
  of the box. Validated: Qwen3.5-4B (MLX) ≈ 80 tok/s on an M1 Max.
- **Fix — versioned Python interpreters.** The argv gate only matched `python` / `python3`,
  so conda / Homebrew `python3.12` had its argv skipped — meaning MLX (`mlx_lm`) *and*
  Rapid-MLX servers running under a versioned interpreter went undetected. Now prefix-matched.
- Efficiency is shown in **tok/Wh** (tokens per watt-hour — the familiar battery unit),
  the first release to carry the unit change made after v1.5.0.

## v1.5.0 — 2026-06-18

On-demand benchmarking — measure how fast a model actually runs on *your* Mac.

- **Measure tok/s** — a button in the AI Runtime card runs one short fixed generation and
  reports the exact decode rate (Ollama `eval_count`/`eval_duration`; an OpenAI-compatible
  wall-clock for LM Studio / llama.cpp). Also available as `sscope-cli --bench`.
- **tokens-per-watt** — mean SoC package power over the run (GPU-active samples only) →
  tok/J, Apple Silicon's signature efficiency metric, shown beside tok/s.
- **Per-model record** — each result is stored per model + runtime and shown for the loaded
  model, persisted across launches.
- **Light menu-bar fix** — the menu-bar glyph's "SS" label and bar tracks now adapt to the
  menu-bar appearance (they were invisible on a light menu bar).

Why on-demand: current Ollama ships its embedded llama-server without `--metrics` (so
`/metrics` returns 501) and `/slots` carries no decoded-token count — there is no passive
live tok/s to read, so it is measured directly instead.

## v1.4.0 — 2026-06-16

Menu-bar cockpit + chip-agnostic accuracy.

- **Live 6-bar menu-bar glyph** — CPU / GPU / ANE / Media / memory-usage / memory-bandwidth
  as colored mini bars with a stacked "SS" label, drawn as a bitmap for reliable rendering.
  The whole glyph blinks red on an alert (swap, memory-pressure critical, or GPU throttle).
- **Revamped dropdown** — six color-matched trend graphs mirroring the glyph, each on a
  fixed Y axis matched to its bar (no auto-scale exaggeration); memory usage is now a line
  graph; top processes; and an **Open Dashboard** button that brings the main window
  forward from the background. Tighter, denser layout.
- **Honest AI attribution** — the runtime line distinguishes a loaded runtime from an idle
  daemon (`Ollama (idle)`) and an unmanaged in-app / MLX-Swift workload
  (`in-app / unmanaged`); the dashboard no longer credits an idle daemon for GPU work done
  by another app.
- **Chip-agnostic bottleneck verdict** — *bandwidth-bound* is now judged against the
  machine's **own** observed achievable bandwidth peak (self-calibrating across M1…M5+),
  not a fixed fraction of the theoretical spec. Observed peaks (bandwidth / media / ANE)
  decay slowly toward a floor so a one-off spike no longer pins the normalization. The
  theoretical "% of ceiling" gauge stays for display.
- **Compact dashboard** — smaller card padding / heights / spacing and a narrower default
  window.

## v1.3.0 — 2026-06-15

Local-AI monitoring — a dedicated cockpit for people running LLMs on Apple Silicon.

- **AI runtime detection** — recognizes Ollama, llama.cpp, LM Studio, MLX, Jan, GPT4All,
  and vLLM by process (bundle-first matching, sudoless) and surfaces the active runtime
  with its RAM / CPU.
- **Model memory budget** — "largest model that fits now" + "if you unload <model>" (per
  quant), with a rate-based swap/compression risk signal that warns *before* tokens/sec
  collapse (not the static used%).
- **Runtime API (opt-in, off by default)** — reads the loaded model, the authoritative
  GPU/CPU offload split (Ollama `size_vram/size`), and tokens/sec (llama.cpp `/metrics`)
  from `127.0.0.1`. Nothing leaves your Mac. Settings → "Connect to local AI runtimes".
- **AI Workload classifier** retuned against real M1 Max LLM runs (bandwidth-bound at the
  ~50%-of-theoretical regime real decode actually hits) and stabilized with a rolling
  average so the verdict no longer flickers.
- Menu bar gains AI runtime + model-budget lines; `sscope-cli --ai` one-shot probe.

Design + validation: [`docs/ai-local-features-design.md`](docs/ai-local-features-design.md).
The classifier was calibrated against MoE, dense, and memory-pressured runs on an M1 Max.

## v1.2.0 — 2026-06-14

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

Thanks to @durul for contributing this feature (#2).

## v1.1.0 — 2026-06-14

Renamed **WhisPlayInfo → SiliconScope**.

The project outgrew its origin as a companion utility; the name now reflects what
it is — a general Apple Silicon / SoC inspector. No functional changes to the
metrics in this release.

- App / product name: **SiliconScope** (was WhisPlayInfo)
- Bundle identifier: `ai.calidalab.SiliconScope` (was `ai.calidalab.WhisPlayInfo`)
- SwiftPM targets: `SiliconScope` (app), `SiliconScopeCore` (data library),
  `sscope-cli` (verification CLI)
- Repository: `github.com/kennss/SiliconScope` (the old URL redirects)

> Because the bundle identifier changed, this installs alongside any existing
> WhisPlayInfo rather than upgrading it in place — delete the old app if you have it.

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
