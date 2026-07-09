# SiliconScope

**English** · [Deutsch](README.de.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Website](https://img.shields.io/badge/website-siliconscope.calidalab.ai-5c9efa)](https://siliconscope.calidalab.ai)
[![Release](https://img.shields.io/github/v/release/kennss/SiliconScope?color=2b9348)](https://github.com/kennss/SiliconScope/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kennss/SiliconScope/total?color=2b9348)](https://github.com/kennss/SiliconScope/releases)
[![License: MIT](https://img.shields.io/github/license/kennss/SiliconScope)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-111)

[![#2 Swift Repository Of The Day](https://trendshift.io/api/badge/trendshift/repositories/57307/daily?language=Swift)](https://trendshift.io/repositories/57307)

A **sudoless Apple Silicon system monitor** — a native SwiftUI dashboard **and** a full
menu-bar suite — with first-class **ANE (Neural Engine)**, **Media Engine**, and
**memory-bandwidth** tracking that Activity Monitor and terminal monitors don't surface.

Born from wanting to *see* how on-device AI and media workloads drive the Apple Silicon
accelerators — and grown into a daily-driver monitor that can stand in for iStat Menus.

*Featured on [AAPL Ch.](https://applech2.com/archives/20260620-siliconscope-apple-silicon-mac-system-monitor.html) (JP) and [ifun.de](https://www.ifun.de/siliconscope-ueberwacht-apple-ki-neural-engine-und-speicher-in-echtzeit-282222/) (DE).*

![SiliconScope dashboard with the Replay scrubber](docs/img/dashboard.png)

*The whole machine at a glance — an AI-workload bottleneck classifier, E/P-core overlaid trends, GPU / GPU-memory / ANE / Media, memory measured against the M1 Max's 400 GB/s ceiling, per-core temperatures, power, and live processes. The bar along the bottom is **Replay** (new in 3.0): every metric is recorded, so you can scrub back through a session like a DVR.*

### Menu bar — every metric, iStat-style

Pin any card to its own menu-bar item — **CPU · GPU · Memory · Network · SSD · Sensors · Battery** — each with a live glyph and a rich dropdown. All sudoless.

![The per-metric menu-bar suite](docs/img/menubar.png)

<p align="center">
  <img src="docs/img/menubar-gpu.png" width="250" alt="GPU / Media / Neural dropdown">
  <img src="docs/img/menubar-sensors.png" width="250" alt="Per-core temperatures">
  <img src="docs/img/menubar-cockpit.png" width="250" alt="Combined SS cockpit — workload, all engines, trends, top processes">
</p>

*The richest dropdowns. **GPU / Media / Neural** — GPU, GPU memory, ANE and Media as live meters plus a four-line 60-second trend. **Sensors** — per-unit temperatures from real **E-Core / P-Core / GPU / Memory** sensors (curated SMC keys per chip generation, M1–M5; HID fallback elsewhere). **SS cockpit** — the whole machine in one dropdown: workload verdict, every engine, 60-second trends, and the top processes.*

![Measuring a local model's speed and efficiency](docs/img/benchmark.png)

*On-demand benchmark: "Measure tok/s" runs one short generation and reports the model's decode speed and energy efficiency — **tokens/sec · tokens/Wh** — stored per model.*

> 📊 **Measured tok/s on your Mac?** [Post it in Discussions](https://github.com/kennss/SiliconScope/discussions/5) — a crowd-sourced per-chip table helps others pick the right hardware.

## New in 3.0

### 🧠 Process Inspector — per-process metrics, sudoless

Click any process to open the Inspector. It shows what Activity Monitor can't:
**CPU (P/E split) · IPC · per-process power (W) · memory · disk** — each with a live
sparkline — and the one signal nobody else surfaces per process: **Neural-Engine memory**.
See exactly which app is on the ANE, and how much it's holding.

![Process Inspector — per-process CPU, IPC, power, and Neural-Engine memory](docs/img/inspector.png)

*An on-device transcription app running live (right): 65% CPU at **2.43 IPC**, **0.64 W**, and **762 MB
of Neural-Engine memory** — the ANE footprint no other monitor shows per process. Accelerators
that macOS only reports system-wide (GPU / ANE-power / Media / bandwidth) are labeled as such —
no faked per-process numbers.*

### ⏺ Record & Replay — a DVR for your Mac's metrics

Hit **Record** and SiliconScope streams every metric — CPU, GPU, ANE, Media, bandwidth, power,
sensors, processes — to a compact `.ssrec` file. Then replay the whole dashboard with
**play / pause / scrub / speed**, so you can catch a spike that's already gone by the time you
look at it. It all stays on your Mac; export a recording to share or diff a run later.

![The Replay transport — play / pause / step, scrub, speed, and Save](docs/img/replaybar.png)

*The Replay transport: play / pause / step, scrub the timeline, change speed, and Save the recording.*

## Why I built it

I built SiliconScope while developing **[Spectalo](https://spectalo.calidalab.ai/)**, an on-device AI video player. To see how
it was actually driving the chip, I ended up running two monitors at once — and neither one
fit:

- **asitop / NeoAsitop** had the chip-level numbers, but the TUI was rough to look at and thin
  on detail.
- **btop** was gorgeous and dense, yet blind to exactly what I needed — **ANE (Neural Engine),
  the Media Engine, and memory bandwidth.**

Keeping both open side by side was painful, and a waste of screen space. I started to fork
NeoAsitop and btop to patch the gaps — then decided to do it properly instead: **one native,
good-looking GUI** that surfaces the Apple-Silicon-specific signals and that a normal person,
not just a terminal dweller, can actually read.

So I built it.

And once it existed, I realized it was finally time to part with **iStat Menus** — my daily
monitor for years. That's what **2.0** is: the release where SiliconScope grew the full
menu-bar suite, per-unit sensors, and battery health it needed to take iStat's place on my
own Mac.

## Install

**[⬇ Download the latest DMG](https://github.com/kennss/SiliconScope/releases/latest)**, then:

1. Open the downloaded `SiliconScope-*.dmg`
2. Drag **SiliconScope** into **Applications**
3. Launch it

Signed with a Developer ID and **notarized by Apple** — it opens with no Gatekeeper
prompt. Requires **macOS 14+ on Apple Silicon**. It **updates itself** from here on
(Sparkle) — this is the last DMG you download by hand.

Prefer to build it yourself? See [Build & run](#build--run).

## Highlights

- **Process Inspector** *(new in 3.0)* — focus one process for CPU (P/E split), IPC,
  per-process **power (W)**, memory, disk, and **Neural-Engine memory** — all sudoless
- **Record & Replay** *(new in 3.0)* — record every metric to a `.ssrec` file and replay the
  dashboard with **play / pause / scrub / speed**, like a DVR
- **AI Workload view** — a bottleneck classifier (*bandwidth-bound* / *compute-bound* /
  *thermal-throttled* / *memory-pressured*) with a per-chip **"% of ceiling"** bandwidth
  gauge — answers "what's limiting my local LLM right now?"
- **E-core / P-core split** — per-cluster utilization + real DVFS frequency
- **GPU** — utilization, power, frequency
- **ANE & Media Engine** — Neural-Engine power and media-codec bandwidth (the differentiators)
- **Memory bandwidth** — CPU / GPU / Media / total GB/s (the local-LLM bottleneck signal)
- **Memory** — Wired / Active / Compressed / Free stacked bar + macOS **memory-pressure** alerts
- **Network** ↑/↓ and **Disk** read/write + free space, with live graphs
- **Per-unit temperatures** — real **E-Core / P-Core / GPU / Memory** sensors via curated
  per-generation SMC keys (M1–M5; HID fallback on others), fan RPM, thermal pressure, and
  **GPU throttle detection** (clock held below its rolling peak under pressure)
- **Battery** — charge state, **health %, cycle count, condition** (AppleSmartBattery)
- **Power** — per-domain CPU / GPU / ANE / DRAM / SoC, plus battery
- **Processes** — sort, filter, kill, and **click to inspect** (in-card scroll)
- **Per-metric menu-bar items** — pin CPU / GPU / Memory / Network / SSD / Sensors / Battery
  each to its own menu-bar glyph + dropdown (plus the combined "SS" cockpit glyph)
- **Auto-update** — built-in Sparkle updater; "Check for Updates…" in the menu
- **No `sudo` required.**

## Build & run

Requires macOS on Apple Silicon and the Xcode toolchain.

```bash
xcrun swift run SiliconScope        # SwiftUI GUI (dashboard + menu bar)
xcrun swift run -q sscope-cli       # data-layer verification CLI
xcrun swift build                   # build everything
scripts/build-app.sh                # create dist/SiliconScope.app locally
open dist/SiliconScope.app          # launch the local app bundle
```

> Use `xcrun`. A non-Xcode `swift` (e.g. swiftly) may not match the macOS SDK and
> will fail with `Failed to build module 'Foundation'`.

## How it works (all sudoless)

| Data | Source |
|---|---|
| Power (CPU/GPU/ANE/DRAM), residency, memory bandwidth | private **IOReport** framework (symbols resolved at runtime via dyld) |
| CPU usage | `host_processor_info` ticks (matches Activity Monitor) |
| CPU/GPU frequency | IOReport `CPU Stats` / `GPU Stats` × IORegistry DVFS table |
| Memory / swap / pressure | `host_statistics64`, `sysctl` |
| Temperatures (per-unit) | curated per-generation **SMC** FourCC keys + **HID** (`IOHIDEventSystem`) fallback |
| Fans, thermal pressure | **SMC** via IOKit |
| Network / Disk | `getifaddrs` / SystemConfiguration, mounted-volume capacities |
| Battery (charge + health/cycles/condition) | IOPowerSources + **AppleSmartBattery** (IORegistry) |
| Processes | `libproc` |

Verified IOReport channel map: [`docs/ioreport-channels.md`](docs/ioreport-channels.md).
Display spec: [`docs/display-spec.md`](docs/display-spec.md).

### Deep dive — the hard parts

Most of these are private/undocumented APIs with no SDK stub. The patterns below are the
reason people clone this repo — each one is a gotcha that cost a day to figure out.

#### 1. IOReport without `sudo` — and without an SDK stub

`IOReport` carries the good stuff (per-domain power, cluster residency, memory bandwidth) and
needs **no root**. The catch: there's no `.tbd` stub in the SDK, so `-framework IOReport`
fails to link. The fix is to **declare the symbols yourself** and let dyld resolve them from
the shared cache at runtime:

```swift
// Package.swift — link the final binary with dynamic_lookup
linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]
```
```c
// Sources/CIOReport/include/ktop_ioreport.h — your own extern decls (one isolated C target)
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef);
```

Sampling is **two snapshots a short interval apart (~175 ms), then `…SamplesDelta`** — power
and residency are deltas, not instantaneous values. All private declarations live in one C
target (`CIOReport`) so the unsafe surface is contained and the Swift side stays clean.

> Trade-off: private API ⇒ **no App Store sandbox**. Self-distribute (sign + notarize). The
> `dynamic_lookup` flag is broad — it defers *all* undefined symbols to runtime, so a real
> link typo only surfaces on launch. Worth knowing.

#### 2. Per-unit temperatures: curated SMC keys, HID fallback

On Apple Silicon a naive SMC "scan all `T…` keys" returns almost nothing useful, and the HID
sensor set (`IOHIDEventSystemClient`, `PrimaryUsagePage 0xff00` / usage `5`) returns *many*
sensors but with cryptic PMU names (`PMU tdie3`, `tcal`). iStat-style friendly names come from
a **hand-curated, per-generation map of SMC FourCC keys read directly** (not scanned):

```swift
// SensorCatalog.swift — detected from the CPU brand string (M1…M5)
cpu([("Tp09","E-Core 1"), ("Tp01","P-Core 1"), ("Tp05","P-Core 2"), …]) +
gpu([("Tg05","GPU 1"), …]) + mem([("Tm02","Memory 1"), …])
```

The keys are near-arbitrary and change every generation (tables adapted from
[Stats](https://github.com/exelban/stats)). Fallback chain: **curated SMC → HID set → SMC
scan** (Intel). Variants (Pro/Max/Ultra) need no special-casing — absent keys simply don't
read back and are skipped.

#### 3. E/P-core split + real DVFS frequency

Topology from `sysctl hw.perflevel0/1`; per-core utilization from `host_processor_info` ticks
(the same source Activity Monitor uses). Frequency is residency-weighted: IOReport gives time
spent in each DVFS state, and the **state→MHz table comes from IORegistry** (`voltage-states*`),
so the reported MHz is what the cluster actually ran at, not a nominal max.

#### 4. ANE & memory bandwidth (with an honest caveat)

The IOReport **Energy Model** group exposes per-domain power including the Neural Engine, and
the bandwidth channels give CPU/GPU/Media/total GB/s. **ANE "usage" is a power-normalized
estimate** — Apple doesn't expose ANE occupancy, so it's labeled as an estimate rather than
faked as a percentage.

#### 5. Dynamic per-metric menu-bar items (AppKit, not SwiftUI)

Each metric becomes its own menu-bar item you can toggle. SwiftUI's `MenuBarExtra` can't do
this: a conditional scene won't compile (SceneBuilder has no `buildOptional`), and
`MenuBarExtra(isInserted:)` triggers a main-menu update **loop** (beachball). The working
answer is AppKit — an `NSStatusItem` + `NSPopover` per enabled metric, reconciled against the
toggles each tick. Live glyphs are drawn to `NSImage` (a live SwiftUI `label:` collapses to
zero width in a status item).

#### 6. Auto-update in a pure-SPM app

Sparkle via SPM, with **no Xcode project**: `package.sh` embeds `Sparkle.framework`, fixes the
rpath, signs nested helpers deep→shallow, then runs `generate_appcast`. The feed is the
**latest GitHub release's `appcast.xml`** (`…/releases/latest/download/appcast.xml`), so each
release just attaches the DMG + appcast and the app updates itself.

#### 7. Per-process metrics — including ANE memory — without `sudo`

The Process Inspector's numbers come from **`proc_pid_rusage(pid, RUSAGE_INFO_V6, …)`** — a
*public* SDK call (no entitlement, no root for processes you own). `rusage_info_v6` carries far
more than CPU time: `ri_instructions` / `ri_cycles` (real **IPC**), `ri_energy_nj` (per-process
**power**, in nanojoules), `ri_user_ptime` (the **P-core** share), disk bytes, wakeups — and the
one that matters most here, **`ri_neural_footprint`: per-process Neural-Engine memory.** That's
the only genuinely per-process ANE signal Apple exposes, so the Inspector shows ANE *memory* per
app but keeps GPU / ANE-power / Media / bandwidth labeled **system-wide** (Apple doesn't
attribute those to a pid — and faking it would be worse than honest). Counters are turned into
rates by delta-over-dt between ticks; a `ri_proc_start_abstime` check guards against pid reuse.

## Not on the Mac App Store

SiliconScope uses private (un-entitled) APIs (IOReport, SMC, HID), so it cannot be
sandboxed/notarized for the App Store. Distribute directly. This is the same
trade-off as NeoAsitop, macmon, mactop, and Stats.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The most useful contribution right now:
**verify the per-chip temperature keys.** The M1 table is hardware-validated; **M2–M5 are
adapted but unverified**. On an M2/M3/M4/M5, run `xcrun swift run -q sscope-cli --sensors`
(+ `sysctl hw.model machdep.cpu.brand_string`) and open an issue with the output.

## Related

**[Spectalo](https://spectalo.calidalab.ai/)** — a beautiful video player with **on-device** AI
subtitles & translation (Whisper + Apple Intelligence), from the same lab (Calida Lab). SiliconScope
was born from building it. Free open beta on TestFlight — same ethos: nothing leaves your device.

<a href="https://spectalo.calidalab.ai/"><img src="docs/img/spectalo-library.jpg" width="520" alt="Spectalo — on-device AI video player with on-device subtitles & translation"></a>


### More from Calida Lab

Privacy-first, on-device software — mostly for Apple Silicon:

- **[SpectaLing](https://spectaling.calidalab.ai/)** — on-device transcription + live translation & interpretation (Mac/iPad). A privacy-first MacWhisper alternative.
- **[SpectArk](https://spectark.calidalab.ai/)** — versioned incremental backup for macOS: snapshots the moment a file changes.
- **[SnowChat](https://snowchat.calidalab.ai/)** — end-to-end encrypted messenger on our own Signal-protocol library.
- **[SnowClaw](https://snowclaw.calidalab.ai/)** — a reference architecture for privacy-preserving agentic AI (working paper).

**→ [www.calidalab.ai](https://www.calidalab.ai/)** · [@kennss](https://github.com/kennss)


## Acknowledgements

- IOReport / SMC / HID sensor knowledge referenced from **NeoAsitop** (MIT) and
  **SocPowerBuddy**; the per-generation SMC temperature key→name tables are adapted from
  **[Stats](https://github.com/exelban/stats)** (MIT). The data layer is written from
  scratch — declarations/facts referenced, no code copied.
- Auto-update by **[Sparkle](https://sparkle-project.org)**.
- Design language inspired by **btop**.
- Further reading on *why* local LLMs run on the GPU (Metal) rather than the ANE — the very
  distinction SiliconScope's AI view is built around:
  [**muramoto's measured deep-dive on the ANE for LLM inference**](https://zenn.dev/salescore/articles/776dff7a85f781)
  (Japanese, Zenn) — shows the ANE wins for small fixed-shape models (Whisper, ViT, embeddings)
  but loses to the GPU on 4B+ LLMs. Shared by
  [@KoheiKanagu](https://github.com/KoheiKanagu)

## License

MIT © 2026 Kennt Kim — see [LICENSE](LICENSE).
