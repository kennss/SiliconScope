# Changelog

## v4.0.3 — 2026-07-24

- **A machine with no GPU now actually appears.** 4.0.2 fixed the decode, but the UI still required
  a GPU: the overview tile was gated on one, so a Raspberry Pi (or CPU-only server, or VM) connected
  and reported yet sat on "Connecting…" indefinitely. Tiles now draw CPU/RAM — which every machine
  has — and add the GPU/VRAM row only when there is a GPU; the Linux detail view drops the GPU chart
  and identity columns instead of showing an empty card.
  ([#33](https://github.com/kennss/SiliconScope/issues/33))

## v4.0.2 — 2026-07-24

- **A remote machine with no GPU now works.** The Linux agent returned a nil GPU list when
  `nvidia-smi` wasn't present, which Go marshals as `null` — so any GPU-less box (Raspberry Pi,
  CPU-only server, VM) was rejected by the viewer with
  `DecodingError.valueNotFound … Path: gpus` and never appeared. The agent now always sends an
  array, and the viewer treats a null or absent array as empty for every field in the schema, so
  machines still running the older agent recover without reinstalling it.
  ([#33](https://github.com/kennss/SiliconScope/issues/33) — thanks to @readingsnail for the
  Raspberry Pi report)

## v4.0.1 — 2026-07-23

- **The Fleet menu-bar icon is gone.** 4.0.0 added it as an always-on item with no way to turn it
  off, while every other menu-bar item (CPU, GPU, Memory, Network, SSD, Sensors, Battery) is opt-in
  and off by default. Menu-bar space is scarce and one app shouldn't take a second slot uninvited.
  The fleet is still one click away in the window's **Devices** sidebar — which is where the icon's
  menu led anyway. ([#31](https://github.com/kennss/SiliconScope/issues/31))

## v4.0.0 — 2026-07-23

**SiliconScope stops being a monitor for *this* Mac.** The 4.x line watches a whole fleet — a
headless Mac mini, a Linux GPU box under the desk, a rented cloud instance — from one window, with
the same depth it always had locally. Nothing about single-Mac use changes; the sidebar simply
starts empty.

**🛰 Fleet monitoring — your other machines, in the same dashboard.** Install a small agent on a
remote box and it appears in a new **Devices** sidebar next to **This Mac**. A remote **Mac** renders
in the *exact* dashboard the local one uses — E/P cores, GPU, **Neural Engine**, Media, memory
bandwidth, power, fans. As far as we know this is the only tool that shows a **remote Mac's ANE**.
A **Linux/NVIDIA** box gets a GPU-centric view instead — utilization, VRAM, power against the card's
limit, temperature, the processes holding VRAM, and any Ollama models loaded — because pretending a
3090 has E-cores would be a lie.

**🗂 Fleet overview — which box is busy, in one screen.** A grid of tiles, This Mac always first,
each with paired trend graphs: **GPU + VRAM** and **CPU + RAM** on every machine, plus **ANE +
memory bandwidth** on Apple Silicon. The metric word in each caption is tinted to match its line, so
the graphs need no legend. Click a tile to drill in.

**🔒 Encrypted, paired, sudoless.** Agents serve over **TLS** with a **bearer token**, and the viewer
pins the agent's certificate on first connect (TOFU), so a re-keyed or spoofed agent is refused
rather than silently trusted. Machines on your LAN are found automatically over mDNS — no IP
configuration. The metrics themselves are read the same sudoless way as always.

**📋 One line to install, one paste to pair.**

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

That URL is the same on every platform — it installs a systemd service on Linux and hands off to the
Mac installer on macOS. The Mac agent needs **no sudo** (a LaunchAgent runs in your own session), so
it finishes unattended over `ssh`. Each installer ends by printing a single `sscope://pair…` link
carrying the machine's name, address and token: paste it into **Add machine…** and the box is added
*and* paired in one step. On a Mac you actually sit at, **Settings → Share this Mac** is the whole
setup.

**🌍 Off-LAN machines — Tailscale, VPN, cloud.** mDNS only reaches the local subnet, so a lab GPU
server or cloud instance can be added by address; everything above it — TLS, token, cert pin — is
identical. Prefer reaching those over Tailscale or an SSH tunnel rather than exposing the port
publicly.

**Honest about the edges.** A remote Linux box reports GPU data only where `nvidia-smi` exists.
Per-sensor temperature lists aren't sent, so a remote Mac's Sensors card says so instead of inventing
values. Pairing is keyed by the machine's name, so renaming a machine means pairing it again. And a
headless Mac needs **Remote Login** enabled before you can install anything on it — that part is
Apple's.

## v3.2.1 — 2026-07-21

- **Memory bandwidth & Media Engine now report on M4 Max and M5 Max.** On recent Apple Silicon +
  macOS 26 the classic "AMC Stats" IOReport group became unsubscribable, so bandwidth and the Media
  Engine read 0 on these chips. SiliconScope now falls back to the PMP residency-histogram source and
  resolves its group name across chip generations ("PMP" → "PMP0" on M5 Max), restoring the Bandwidth
  / Media rows and the AI Workload bandwidth-bound verdict.
  ([#14](https://github.com/kennss/SiliconScope/issues/14),
  [#29](https://github.com/kennss/SiliconScope/pull/29),
  [#30](https://github.com/kennss/SiliconScope/issues/30) — thanks to the reporters for
  hardware-verified diagnoses on M4 Max and M5 Max)
  - The `AMCC` memory-controller aggregate is excluded from the per-requestor sum, so it no longer
    inflates "other" / total on the histogram path.
  - New `sscope-cli --bandwidth` diagnostic dumps the raw bandwidth-channel inventory, so a new
    chip/OS layout can be reported quickly.
- **Older recordings keep loading.** Fixed a regression where `.ssrec` files recorded before these
  bandwidth changes failed to decode and opened empty.
- **Honest AI Workload copy.** The docs and site described a numeric "% of ceiling" gauge that isn't
  rendered — the bandwidth-vs-ceiling read surfaces as the qualitative "Bandwidth-bound" verdict; the
  copy now matches.

## v3.2.0 — 2026-07-15

- **Much lighter — dramatically lower CPU and energy use.** SiliconScope had been using far more
  energy than a monitor should (Activity Monitor "Energy Impact" ~836 — comparable to a web
  browser). A deep profiling pass traced nearly all of it to a handful of samplers doing redundant
  work every second, the largest by far being the peripheral-battery reader walking the *entire*
  IORegistry on each scan. Rebuilt across the data layer: **~85% lower Energy Impact** and
  window-open CPU cut from ~24% to ~10%, with no loss of data or features.
  ([#28](https://github.com/kennss/SiliconScope/issues/28))
  - The dashboard now **fully stops rendering when its window is closed** — it had been redrawing at
    full rate to a hidden window.
  - Peripheral-battery, disk-capacity, GPU-memory and battery-health reads now refresh on their
    natural cadence and are reused between ticks; the process table and AI-runtime detection cache too.
  - Menu-bar glyphs are re-rasterized only when their pixels actually change.
  - Charts render through a lightweight Canvas instead of Swift Charts.
- **Tighter AI Workload card** — trimmed the per-engine row spacing.

## v3.1.5 — 2026-07-06

- **Fixed: the Processes list was missing most of your processes.** `ProcessSampler` divided the PID
  count returned by `proc_listallpids` by four, so the process table — and the "top process" the AI
  Workload card names — was built from only a fraction of what's actually running (verified: 277 of
  719 samplable processes). It now enumerates the full table, so the process list and top-CPU
  attribution are complete. Thanks **@Collinw24** ([#26](https://github.com/kennss/SiliconScope/pull/26)).
- **New runtime: oMLX.** SiliconScope now detects the native Apple Silicon **oMLX** inference server
  (with optional API-key auth) alongside Ollama, LM Studio, MLX, vLLM, exo, and the rest — so the AI
  Workload verdict and one-click benchmark cover it too. Also **@Collinw24** ([#26](https://github.com/kennss/SiliconScope/pull/26)).

## v3.1.4 — 2026-07-05

- **Fixed: the Memory & Bandwidth card could overlap the CPU card above it.** The chart work in 3.1.2
  put a fixed height back on that row, which re-introduced the overflow 3.1.1 had fixed — so on some
  macOS versions (reported on macOS 15.7) the dense memory column spilled over the card above it. That
  row now grows to fit its content again, so it can't overflow — on any macOS version. Thanks
  **@kyrarae** ([#25](https://github.com/kennss/SiliconScope/issues/25)).

## v3.1.3 — 2026-07-04

- **The chart gridlines are now actually visible.** The dotted grid added in 3.1.2 was too faint to
  make out; bumped its contrast so it does its job. ([#24](https://github.com/kennss/SiliconScope/issues/24))

## v3.1.2 — 2026-07-04

**Clearer charts + a per-engine accelerator breakdown.**

- **Timeline charts fill the card and get a dotted grid.** The CPU and GPU trend charts now use the
  card's full height (no more short chart floating above a gap) and sit on a faint dotted grid, so
  the level reads clearly even at 100%. Thanks **@Borda** ([#24](https://github.com/kennss/SiliconScope/issues/24)).
- **GPU / ANE / Media are now separate engine rows.** The AI Workload card's accelerator line used to
  collapse to a single state — so a Neural-Engine workload showed "ANE active" under a "GPU" label.
  Each engine now has its own honest row, so you see exactly where a workload lands: CoreML ASR →
  **ANE active** while the GPU stays idle, a local LLM → **GPU active**, video → **Media**.

## v3.1.1 — 2026-07-03

- **Fixed: the header could be overlapped by the cards below it.** On some macOS versions (reported
  on macOS 15.7) the title / chip / power-battery row was partly covered by the top cards. Dashboard
  rows now grow to fit their content instead of using a fixed height, so nothing overflows into the
  header — on any macOS version. Thanks **@blueinkgz** ([#23](https://github.com/kennss/SiliconScope/issues/23)).

## v3.1.0 — 2026-07-03

**A workload-state cockpit, CPU throttling, and one-click process kill.**

- **The AI Workload card is now a live state summary.** Instead of repeating the bandwidth /
  GPU numbers already shown in their own cards, the top-left card reads out *what the workload
  is and where it lands*: a headline verdict (**LLM (GPU/Metal)** / **ANE (CoreML)** / GPU active
  / Idle) over three colour-coded engine states — **CPU** (with its top process), **GPU / Media /
  ANE**, and **Memory** — plus the signature **Mem BW % of ceiling** gauge (how close token
  generation is to the memory-bandwidth wall). It describes the silicon; it never advises.
- **CPU thermal throttling.** The throttle story used to be GPU-only. Now the **CPU card turns its
  border red and shows a "P ceiling" line** (e.g. *1765 / 3228 MHz · −45% thermal*) when the
  performance cores are held below the chip's top clock by heat — symmetric to the GPU card.
- **Kill a process where you already see it.** A hover **Kill** on any Processes row, right-click
  **Kill / Force Kill** on the AI Workload card's top process (tap it to open the Inspector), and
  **Kill / Force Kill** buttons in the Inspector itself. Systems vocabulary (SIGTERM / SIGKILL),
  always user-initiated behind a confirm — never a suggestion. Idea sparked by **@zhangchen456**
  ([#22](https://github.com/kennss/SiliconScope/pull/22)).

## v3.0.4 — 2026-07-02

**Dashboard graphs + a new runtime.**

- **Memory usage over time.** The Memory & Bandwidth card now plots memory-used as a labelled
  sparkline stacked alongside the bandwidth trend (in the bandwidth column, like the Network & Disk
  card's two graphs) — so you can see how memory has evolved across the session, not just the
  current split. Thanks **@Thoralf-M** ([#20](https://github.com/kennss/SiliconScope/issues/20)).
- **exo is now a recognized AI runtime.** SiliconScope detects
  [exo](https://github.com/exo-explore/exo) and reads its loaded model over the OpenAI-compatible
  API on `127.0.0.1:52415` (opt-in, localhost only). Thanks **@nickalexej**
  ([#21](https://github.com/kennss/SiliconScope/issues/21)).
- **Quieter, clearer warnings.** Memory-pressure / GPU-throttle warnings no longer flicker on and
  off every second — they linger briefly then clear once, the affected card's border tints
  amber/red so you can see *which* metric tripped, and the whole banner is now toggleable in
  Settings. Thanks **@muescha** ([#18](https://github.com/kennss/SiliconScope/issues/18)).

## v3.0.3 — 2026-07-02

Full support for the **base M1** (MacBook Air M1 / Mac mini / iMac) — two fixes that only
affected the non-Pro/Max M1:

- **Sensor names now map correctly.** The Sensors panel showed raw HID labels
  (`eACC/pACC/SOC MTR Temp Sensor`) on base M1; they now read **E-Core / P-Core / GPU / ANE /
  SoC** like every other chip.
- **Per-component power now reads.** CPU (E/P), GPU, ANE, and DRAM power showed **0 W** on base
  M1 — those rails live in a different IOReport group there (`PMP`), which SiliconScope now reads.
  On-device **Whisper / Core ML** ANE draw now shows up on a MacBook Air.

## v3.0.2 — 2026-06-30

- **Run as a pure menu-bar utility (optional).** A new **Show Dock icon** setting (default on):
  turn it off and the Dock icon disappears — SiliconScope lives entirely in the menu bar, and the
  dashboard still opens from any menu-bar item's dropdown. Idea from **@zhangchen456**
  ([#17](https://github.com/kennss/SiliconScope/pull/17)).

## v3.0.1 — 2026-06-30

**Stability & UI polish.**

- **Closing the window no longer quits the app.** SiliconScope is a menu-bar-resident monitor, so
  closing the dashboard now just hides it — the app stays live in the menu bar, and "Open
  Dashboard" (or a Dock-icon click) brings it right back.
- **Warning hints no longer shove the layout around.** Memory-pressure and GPU-throttle alerts used
  to be inserted inline at the top, pushing every card down (and back up) as the condition came and
  went. They now float as a dismissible overlay (✕ to close) while the condition holds, so the
  cards stay put. Thanks **@muescha** ([#16](https://github.com/kennss/SiliconScope/issues/16)).
- **Lighter when it's not on screen.** The live charts now pause rendering while the window is
  minimized or fully covered (the data sampling itself was already negligible).
- **AI Workload reads better under throttling.** When the GPU is thermal-throttled the card now
  shows the clock value — e.g. *580 MHz (−55% vs peak)* — in red next to the verdict, instead of a
  prose blurb that got truncated in the half-width card.

## v3.0.0 — 2026-06-26

**A new way to observe your Mac: rewind time, and zoom into one process.** The 3.x line adds
two big capabilities on top of the live dashboard.

**🔴 Record & Replay — a DVR for your Mac.** Hit **Record** in the bottom bar to capture *every*
metric (1 Hz, all engines/temps/power/bandwidth/processes) to a `.ssrec` file; press **Stop** and
the dashboard drops straight into **replay** — play / pause / step / scrub / 0.5–4× speed, with the
*entire dashboard* (sparklines, AI-workload verdict, peaks, temps) re-rendered exactly as it looked
at each moment. **Save** writes both the lossless `.ssrec` (re-openable) and a flattened `.csv` (for
Excel/Python), timestamped, to `~/SiliconScope`. As far as we know, the first Mac monitor with a
true record/replay. (Reopen any `.ssrec` later via the Replay menu or by dropping it on the window.)

**🔬 Process Inspector — per-process detail no other Mac GUI shows.** Click a process to open a live
Inspector: **CPU** (with P-core/E-core split), **Compute** (IPC, instructions/s, cycles/s),
**Energy** (actual watts + wakeups), **Memory** footprint, **Disk** I/O — and, uniquely,
**Neural-Engine memory** (whether and how much a process is using the ANE). All sudoless, via
`proc_pid_rusage`. Honest about limits: GPU / ANE-power / Media / bandwidth can't be attributed to a
single process on macOS, so they're shown clearly labeled "system-wide."

**⚡ Snappier + finer.** The four IOReport/CPU samplers now run in parallel (≈0.8 s → ~0.2 s per
tick), and the recording cadence follows your refresh-interval setting.

## v2.4.1 — 2026-06-24

**MacBook Neo (A18 Pro) now reports power and memory bandwidth.** On the A18, the usual IOReport
power/bandwidth channels read zero (the Energy Model only populates GPU, and there's no
per-requestor bandwidth), so SiliconScope now reads the A18's real sources instead:

- **System power** from SMC `PSTR`, and **CPU package power** from SMC `PZC0` (verified jumping
  from ~0.8 W idle to ~6.2 W under load).
- **Total memory bandwidth** by summing the IOReport `PMP` → `DRAM BW` lanes.

That makes SiliconScope the first Mac monitor to surface power and bandwidth on the MacBook Neo —
which, together with GPU usage, drives the AI-workload (bandwidth- vs compute-bound) read on the
Neo too. Per-component ANE/Media and the CPU E/P split aren't exposed by the A18 and remain
unavailable. Huge thanks to **@Dreaminko** ([#12](https://github.com/kennss/SiliconScope/issues/12)),
who ran the diagnostic dumps that mapped all of this.

## v2.4.0 — 2026-06-24

**Hide the combined menu-bar icon + reach Settings from anywhere.** On notch-limited menu bars,
you can now turn off the combined "SS" icon (Settings → Menu bar items → **Combined (SS)**) to free
a slot and keep just the per-metric items you want. Since the SS dropdown used to hold the only
Settings link, **every per-metric dropdown now has a Settings + Dashboard footer**, so nothing is
stranded when SS is hidden. (Thanks to community feedback.)

**Recognizes the A18 Pro (MacBook Neo).** SiliconScope now identifies the A18 Pro instead of
showing an unknown chip; CPU topology, frequencies, temperatures (HID), and memory work, and it
degrades gracefully where the A18's IOReport power/bandwidth channels differ from the M-series.
Full power/bandwidth mapping is in progress (#12).

## v2.3.0 — 2026-06-22

**Connected-peripheral battery in the Battery dropdown.** Open the Battery menu-bar item and a new
**Peripherals** section (right under the main battery) shows the battery of connected accessories —
Apple Magic Mouse / Trackpad / Keyboard (via IORegistry) and AirPods with a Left / Right / Case
breakdown (via system_profiler). Only devices that report a real value are listed (no blank rows),
low (≤20%) shown in red, all sudoless and sampled on a light cadence. (Bluetooth Logitech devices
like the MX Master expose battery only over a proprietary GATT path macOS doesn't surface, so
they're omitted rather than shown empty.)

Sensors: **M4 Pro/Max GPU 1/2** — adds the `Tg1U` / `Tg1k` keys those dies use, confirmed from an
M4 Max sensor dump (#6). Also a new contributor diagnostic, `sscope-cli --sensors-all`, which lists
every present SMC temperature key (flagging ones not yet in the curated table) to help map sensors
on chips SiliconScope doesn't fully cover yet.

## v2.2.3 — 2026-06-22

Sensors: **a fuller temperature panel on partially-mapped chips (e.g. M4 Max).** When a die
exposes only a subset of its generation's curated SMC keys — M4 Max, for instance, reads back no
Memory key — SiliconScope now fills the intended-but-absent category from the HID sensor set
instead of leaving it blank. Per-core readings the chip genuinely doesn't expose are never
fabricated, and fully-mapped chips (M1–M3) are untouched, with no extra cost. Follows up the M4
Max report (#6).

Also adds a contributor diagnostic, `sscope-cli --power-debug`, which dumps every IOReport power
channel across all groups so non-M1 users can report where a rail lives on their chip (e.g.
whether ANE power sits in `Energy Model` or `PMP` on M2). Follows up #11.

## v2.2.2 — 2026-06-21

Fix: **CPU core frequencies read as ~1–5 MHz on M4** (both E and P clusters). M4 changed the
`voltage-states` DVFS tables from Hz (M1–M3) to KHz, so the old Hz→MHz conversion collapsed them
to near-zero. Frequencies now rescale automatically when the Hz reading is implausibly low —
chip-agnostic, so it also covers any future unit change. M1–M3 are unaffected, and the GPU clock
(still reported in Hz on M4) was already correct. Thanks to [@Borda](https://github.com/Borda)
for the detailed M4 Max report (#6).

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
