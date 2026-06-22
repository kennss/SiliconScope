# Roadmap — next version

v1.0.0 is a general Apple Silicon monitor. The next version specializes toward
**AI-inference monitoring** on Apple Silicon — the niche neither terminal monitors
nor Activity Monitor cover.

## What's next — backlog (updated 2026-06-22)

Current actionable items, roughly by priority. Detail follows below / in the linked notes.

- [ ] **Battery monitoring expansion** — see the dedicated section below. On-brand, sudoless,
  *monitoring* only (NOT charge control — that needs SMC writes + a privileged helper, which
  breaks the sudoless/read-only identity; AlDente owns that space and is a complement, not a
  competitor).
- [ ] **Remove the "Compact GPU mode (menu bar)" setting** (legacy v1.x) — see below.
- [ ] **Cut the next release** to ship what's already on `main` but unreleased since v2.2.3:
  `sscope-cli --sensors-all` (full SMC T-key dump for mapping unmapped chips) and the
  `String(cBuffer:)` deprecation cleanup. (`--power-debug` already shipped in v2.2.3.)
- [ ] **M4 Max sensor mapping (#6)** — awaiting a `--sensors-all` dump from an M4 Max owner
  (Borda/KoheiKanagu). The `*`-flagged keys reading plausible per-core temps are the missing
  E-Core 3/4, P-Core 5, Memory sensors; add them to `SensorCatalog.m4` once identified.
- [ ] **M2 ANE channel (#11)** — awaiting a `--power-debug` dump from an M2 owner. If ANE power
  sits in the `PMP` group (not `Energy Model`) on M2, extend `PowerSampler.sample()` to scan it.
- [ ] **Homebrew cask** — validated & ready; blocked only by the 30-day repo-age rule →
  submit ~2026-07-08. See the `homebrew-cask-plan` memory note.
- [ ] **mlx-serve runtime detection** — deferred until it's bigger; recipe in the
  `runtime-detection-watch` memory note.

## TODO — battery monitoring expansion

We already read battery charge/charging-state + health/cycles/condition/temp sudolessly from
`AppleSmartBattery` (IORegistry) and `IOPowerSources` (see `Battery.swift`). Extend the
*monitoring* (never control), all sudoless:

- [ ] **Charge / discharge rate (W)** — instantaneous power in/out, signed (charging vs
  draining). Source: `AppleSmartBattery` `InstantAmperage` × `Voltage` (or `BatteryData`),
  or `IOPSGetPowerSourceDescription`. Show as a live value + sparkline like the other metrics.
- [ ] **Time to full / time to empty** — `IOPowerSources` exposes `TimeToFullCharge` /
  `TimeToEmpty` (minutes; -1 = "calculating"); or derive from the rate above + remaining
  capacity. Display whichever applies to the current charging state.
- [ ] **Adapter wattage** — `AppleSmartBattery` `AdapterDetails` dict (`Watts`, `Description`,
  `Voltage`, `Current`): show the connected charger's rated W and whether it's delivering full
  power (useful for "is this cable/charger underpowering me?").
- [ ] **Charging state detail** — beyond a bare %: `IsCharging` / `FullyCharged` /
  `ExternalConnected`, plus "not charging on AC" (held by macOS Optimized Battery Charging /
  the 80% limit). Makes "why isn't it charging?" legible.
- [ ] **Battery temperature trend** — we already read battery °C; add a rolling history
  sparkline (same treatment as CPU/GPU temp).
- [ ] **Health time-series** — persist a periodic sample of health (max/design capacity) +
  cycle count so degradation is visible over weeks/months, not just a point-in-time number.
  (Cycle count moves slowly — sampling daily is enough.)

UI: likely a richer **Battery** dropdown / dashboard card grouping these, gated on
`hasBattery` (desktops — Mac mini/Studio/Pro — have none; branch like the fanless `fan_exist`).

### Peripheral battery in the battery dropdown (à la iStat Menus)

Optional: show connected accessories' battery when the user opens the battery dropdown — a
reasonable, iStat-precedented convenience (NOT a full multi-device dashboard; that's
AirBattery's job). **Verified sudoless sources on a real machine (2026-06-22), per device type:**

| Device type | Sudoless source | Effort |
|---|---|---|
| Apple Magic Mouse / Trackpad / Keyboard | IORegistry `BatteryPercent` (+ `BatteryStatusFlags`) on the HID node | **Easy** |
| AirPods (L / R / Case) | `system_profiler SPBluetoothDataType` → `Left/Right/Case Battery Level` | **Easy** (parse) |
| Other standard BLE-Battery-Service devices | same as above (macOS aggregates) | Easy |
| **Logitech (e.g. MX Master 3S)** | **NOT** in IORegistry/`system_profiler` — needs **HID++** feature-report query over IOHIDDevice | **Medium**, vendor-specific |

Notes / gotchas:
- `system_profiler SPBluetoothDataType` spawns a process and takes ~1–2 s → **cache it, refresh
  ~every 60 s** (peripheral battery changes slowly), never per tick.
- AirPods report only while connected/advertising; values go stale/absent when cased.
- Logitech HID++ would be a genuine differentiator (even macOS's own battery menu can't show
  MX Master without Logi Options+), but it's per-vendor work and can break across firmware.
- **Not a reverse-engineering job — adapt an existing impl.** HID++ battery is well-solved:
  open the device via `IOHIDDevice`, send a HID++ 2.0 feature report (Battery Status `0x1000`
  / Unified Battery `0x1004`), parse the %. Sudoless (HID feature reports don't need root).
  License-clean references (adapt protocol/logic + attribute, like we do for NeoAsitop):
  **MIT** — [Mouser](https://github.com/TomBadash/Mouser) (Python, MX 2/3/3S),
  [batteryconsole](https://github.com/omar16100/batteryconsole) (Rust, macOS-only, exactly this);
  **Apache-2.0** — [OpenLogi](https://github.com/AprilNEA/OpenLogi) (Rust, 5.2k★).
  Swift/IOKit mechanics can be *learned* from [optune](https://github.com/Sanjays2402/optune)
  (Swift) but it's **GPL-3.0 → reference only, write our own** (SS license is undecided).

Suggested phasing: (1) Mac's own battery expansion above → (2) easy peripheral tier (Apple
Magic via IORegistry + AirPods via system_profiler) → (3) Logitech HID++ if wanted.
Dev's own kit spans all tiers (Magic Mouse 2 + Magic Trackpad + AirPods Pro = easy; MX Master 3S = HID++).

## TODO — cleanup

- [ ] **Remove the "Compact GPU mode (menu bar)" setting** (legacy v1.x). It swapped the SS
  combined dropdown for a one-line GPU readout — now redundant with the per-metric GPU
  menu-bar item + rich dropdown, and confusing (even the dev forgot what it did). Delete the
  `compactGPUMode` @AppStorage, the Settings toggle, and the `compactGPURow` branch in
  MenuBarView (always use the full readout).

## Shipped (v1.1.0 – v1.7.0)

- **AI Workload view (hero)** — a bottleneck classifier with a single verdict:
  *bandwidth-bound* / *compute-bound* / *thermal-throttled* / *memory-pressured*
  (plus *idle* / *GPU-active*). Front-and-center hero card on the dashboard, mirrored
  as a `Workload:` line in the menu bar. Precedence: memory > thermal > workload profile.
- **Per-chip memory-bandwidth ceiling table** + a **"% of ceiling" gauge**
  (M1–M4; Max bins disambiguated by P-core count; self-corrects up to the observed peak
  for chips outside the table).
- **GPU throttle detector** — flags the GPU clock held below its slowly-decaying rolling
  peak while thermal pressure has risen above nominal (banner + menu-bar flame).
- **Compact GPU menu-bar mode** — single line: `GPU% / GPU W / GPU GB/s / die °C`.
- **AI runtime detection** — recognizes `ollama`, `llama.cpp`, `LM Studio`, `MLX`, `Jan`,
  `GPT4All`, `vLLM` by process (bundle-first match) and surfaces them in an AI cockpit card.
- **Model memory budget** — two figures (fits-now / if-you-unload) + "largest model that
  fits" per quant, with a rate-based swap/compression risk signal.
- **Runtime API (opt-in)** — reads loaded model, authoritative GPU/CPU split (Ollama
  `size_vram/size`), and tokens/sec (llama.cpp `/metrics`) from `127.0.0.1`. Off by default.
  Design: [`ai-local-features-design.md`](ai-local-features-design.md).
- **Menu-bar cockpit (v1.4.0)** — live 6-bar glyph (CPU/GPU/ANE/Media/MEM/MBW) that blinks
  red on alert; revamped dropdown with six color-matched, fixed-axis trend graphs, top
  processes, and an Open-Dashboard (bring-to-front) button; honest AI attribution (loaded
  runtime vs idle daemon vs in-app/MLX-Swift); **chip-agnostic bandwidth-bound verdict**
  judged against the machine's own observed achievable peak (decaying) instead of a fixed
  fraction of the theoretical spec; compact dashboard.
- **On-demand benchmark (v1.5.0)** — "Measure tok/s" runs one short generation → exact decode
  tok/s + **tokens-per-watt (tok/Wh)**, stored per model. Ollama via `eval_count`/`eval_duration`;
  OpenAI-compatible wall-clock for the rest. (Passive `/metrics` is unavailable on current Ollama.)
- **Rapid-MLX support + versioned-Python fix (v1.6.0)** — detect the Rapid-MLX engine (🐇,
  OpenAI-compatible :8000) for model + benchmark; and read argv for `python3.12`-style
  interpreters so conda/Homebrew mlx_lm and Rapid-MLX servers are no longer missed.
- **Daily-driver basics (v1.7.0)** — launch-at-login (SMAppService) + opt-in threshold
  notifications (GPU thermal throttle / memory pressure / swapping; edge-triggered, cooldowned).

## v1.5 roadmap — from "AI monitor" to "local-AI operations"

The metric local-LLM users live by is **tokens/sec**. Build there first, then layer
per-machine learning and RAM hygiene on top — that's what turns a gauge into an operations
tool. Validation came from real M1 Max runs (MoE 26B, dense 12B/31B).

### Tier 1 — speed ✅ done (on-demand benchmark)

- **tokens/sec — measured on demand, not passively.** The assumed passive route does NOT
  work on current Ollama (0.30.8): it runs its embedded `llama-server` **without `--metrics`**
  (→ `/metrics` is 501), and `/slots` carries no decoded-token count. So instead a "Measure
  tok/s" button runs ONE short fixed generation and reads the exact decode rate — Ollama
  `/api/generate` (`eval_count`/`eval_duration`), or an OpenAI-compatible wall-clock for
  LM Studio / llama.cpp. Also `sscope-cli --bench`. (Validated: gemma4:26b ≈ 60 tok/s.)
- **tokens-per-watt (efficiency) ✅** — mean SoC package power sampled over the benchmark
  window (GPU-active samples only) → tok/Wh, shown beside tok/s. Apple Silicon's signature
  metric, near-absent elsewhere.
- **Per-model record ✅** (pulled forward from Tier 2) — each result is stored per
  model+runtime and shown for the loaded model. A history chart / peak-temp log is still open.

### Tier 2 — make it a tool, not just a gauge

- **Per-model performance log.** Record tok/s, peak temp, and power per model+quant over
  time → "what's fast on *my* Mac" (e.g. gemma-12b Q4 ≈ 38 tok/s, qwen-32b Q4 ≈ 12 tok/s).
  Builds directly on Tier 1.
- **Idle-model reclaim nudge.** A model loaded but unused for N minutes while holding
  X GB → suggest unloading. Sudoless — we already detect the loaded model (③) and activity.

### Tier 3 — nice to have

- **Model recommender** — beyond "largest that fits": concrete model/quant suggestions for
  the detected chip + free memory.
- **Context / KV-cache cost** — show how much memory the KV cache adds at 8k / 32k / 128k
  context; warn when a long context eats the budget.
- **AI menu-bar mode** — one line: current model · tok/s · GPU · headroom.
- **"AI app" pin (Settings)** — a user-pinned process name to surface in-app MLX/CoreML
  apps (e.g. WhisPlay via MLX-Swift) that have **no runtime process**. This is the only
  way around the in-app-inference blind spot (see below).
- **Engine attribution** (GPU/Metal vs ANE hint) · **Homebrew cask**.

## Out of scope (sudoless limits)

- **Per-process GPU / ANE attribution** — not reliably available without elevated access.
- **Auto-detecting in-app MLX/CoreML inference** — an app embedding MLX-Swift/CoreML has no
  separate runtime process, so it can't be attributed automatically. Surfaced only via the
  manual "AI app" pin (Tier 3). The tool stays honest meanwhile ("GPU active — type unknown").
- **tokens/sec from chip telemetry alone** — obtained instead from the runtimes' own HTTP
  APIs / metrics (opt-in), never fabricated from SoC counters.

## Compatibility notes / lessons learned

### macOS 27 — launch crash via `Bundle.module` (fixed in v1.0.2)

- **Symptom:** v1.0.0/v1.0.1 crashed immediately on launch under macOS 27
  (`EXC_BREAKPOINT` / `_assertionFailure` in `static NSBundle.module`). Reported in
  issue #1 (Mac14,9, macOS 27.0 beta). Did not reproduce on macOS 26 and earlier.
- **Root cause:** SwiftPM's generated `Bundle.module` accessor calls `fatalError`
  when it cannot locate its resource bundle. We hand-assemble the `.app` (SPM emits
  no bundle), and the copied resource bundle `ktop_WhisPlayInfo.bundle` is a *flat*
  folder with no `Info.plist`. macOS 27 tightened bundle validation and no longer
  treats such a folder as a valid bundle, so every `Bundle.module` candidate path
  returned nil → `fatalError`. Older macOS accepted the flat folder, hiding the bug.
- **Fix (v1.0.2):** the app icon is now resolved via `Bundle.main` (packaged
  `Contents/Resources/AppIcon.icns`) with a manual SwiftPM-bundle fallback for dev
  runs — every `Bundle.module` reference was removed, so the `fatalError` path is
  gone regardless of bundle validity.
- **Forward action (for the Packaging item above):**
  - Never depend on `Bundle.module` in a hand-assembled `.app`; load resources from
    `Bundle.main` or by explicit path.
  - If a SwiftPM resource bundle must be shipped, give it a valid `Info.plist` so it
    is a real bundle on current macOS.
  - Smoke-test releases against the **latest macOS beta** before publishing — this
    class of bug only surfaces on the newest OS.
