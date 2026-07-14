# SiliconScope — Energy / Render Optimization (implementation plan)

> **Status:** v2 — senior review incorporated (verdict: GO with required changes). Ready to
> implement in the sequenced order of §5.
> **Author:** Kennt Kim / Calida Lab · **Created:** 2026-07-14 · **Updated:** 2026-07-14
> Fixes the "SiliconScope is a power hog" reports (issue #28, and a stable-macOS Activity Monitor
> reading of **Energy Impact 836 / 12-hr power 549 — ~200× iStat Menus' 4**). The cost is **UI
> rendering + always-on redraw/enumeration**, *not* the data layer. This doc pins each cause to
> real code with before→after, sequenced into bisectable commits.

---

## 1. Verified root cause (empirical)

A live `sample` profile (PID 91862, v3.1.5) + static tracing by 4 independent agents (each told to
*refute*) converged:

- **~97% of thread-time is idle/parked**; real compute averages **~24% of one core, bursting once
  per second**.
- **Of the main-thread WORK, ~99% is rendering** (sample counts, 10 s run):

  | Bucket | ~samples | What it is |
  |---|---|---|
  | SwiftUI view-graph re-flush (`DoObservers → GraphHost.flushTransactions → AG::Subgraph::update`) | 579 | whole dashboard body re-evaluated each tick |
  | CoreAnimation commit → layout → **Swift Charts** raster | 323 | ~13 live `Chart` sparklines |
  | **Menu-bar status-item re-raster** (`NSStatusItem._updateReplicant → CALayer renderInContext`) | 73 | glyph bitmap rebuilt every tick (**runs even with dashboard closed**) |
  | SwiftUI **accessibility** node recompute | 43 | inside each render |
  | sorting + `proc_info` + sampling on the main thread | ~0 | **not a factor** |

- **Measurement caveat (from review):** Activity Monitor **Energy Impact weights GPU + idle-wakeups**,
  not just CPU thread-time — our `sample` is CPU-only, so it *under-measures* the GPU compositing of
  ~13 layers rebuilt each second. State the conclusion precisely: **"~99% of *CPU thread-time* is
  rendering."** The **Energy-Impact before→after delta (§6) is the real proof**, not the `sample`
  buckets.
- **Refuted — do not chase:** main-thread process sort/filter (~0.01%, 0× when dashboard hidden);
  `proc_info` enumeration as a *CPU* driver (~0.05% — high syscall *count*, low CPU *time*);
  "no occlusion pause" (already exists, `WindowVisibilityObserver`, commit `8b51044`); 60/120 fps
  chart animation (sparklines redraw once per ~1 Hz tick, no animation driver).
- **Secondary background cost** (off-main, heavier than the whole process table): peripheral
  enumeration — `ioRegistryDevices` ~341, `bluetoothAudioDevices` ~335, `runSystemProfiler` ~282
  (spawns `system_profiler`). *Caveat:* the subprocess's own CPU is attributed to **its** row, so
  FIX 4's Energy-number payoff is mostly the fork/exec + parse cost we own — smaller than the raw
  `sample` bucket implies.
- Developer's own in-code note already says it (`DashboardView.swift:19-24`): *"the data layer
  (IOReport/SMC/per-process sampling) is ~0.6% CPU, while the live SwiftUI chart rendering is
  essentially the entire footprint."*

**Two cost regimes** (both feed the 12-hr Energy Impact): **dashboard visible** → Swift Charts +
full-body re-flush (Fixes 1, 2, and the §4a render-rate lever); **menu-bar only (24/7)** → per-tick
glyph re-raster + `system_profiler` (Fixes 3, 4).

## 2. Fix inventory

| # | Fix | File:line | Regime | Impact | Risk | Commit |
|---|---|---|---|---|---|---|
| **1** | Swift Charts `Sparkline` → `Canvas` — **spike first** | `Theme.swift:263-290` | dashboard | **highest** | med | **B** |
| **2** | `.accessibilityHidden(true)` on sparklines | `Theme.swift` Sparkline | dashboard | med | none | A/B |
| **3** | Menu-bar glyph dedupe — **quantized per-glyph signature** | `MetricBarController.swift:117-136` | always-on | med | med | **C** |
| **4** | `system_profiler` cadence — raise `btTTL` 3→30 (keep `peripheralInterval`=5) | `PeripheralBattery.swift:73` | always-on | med | none | A |
| **5** | Cache process enumeration to ~2–3 s cadence | `SystemSampler.swift:89` | always-on | low–med | low | D |
| **6** | Skip redundant `rows` re-sort (live, CPU-sorted) | `DashboardView.swift:1124-1135` | dashboard | low | low | A |

---

## 3. Fix details (current → proposed)

### FIX 1 — `Sparkline`: Swift Charts → `Canvas` — **SPIKE BEFORE THE 13-WAY REWRITE**

**Current** (`Theme.swift:263-290`): each sparkline is a Swift Charts `Chart` with `AreaMark`
(linear-interpolated fill gradient) + `LineMark` (`.interpolationMethod(.monotone)`) + axis/legend
config. ~13 rebuild their mark/scale/plot view-graph *and* rasterize every ~1 s. This is the **323**
(Charts raster) and part of the 579.

**⚠️ Required correction to v1's claim:** Canvas reliably kills the **323**. It does **not** kill the
**579** — that is *whole-dashboard body re-evaluation*: `DashboardContainer` rebuilds
`DashboardState(live: monitor)` every tick (`DashboardView.swift:100`) reading the single
`@Observable snapshot`, so the body re-flushes every second **regardless of Canvas vs Chart**. Canvas
removes only the ~13 Chart sub-graphs' share of that flush. If the 579 dominates, the §4a render-rate
lever is the real fix.

**→ REQUIRED: measured spike first.** Add a parallel `CanvasSparkline` (or convert ONE call site
behind a flag), then `sample <pid> 10` + Energy Impact with the dashboard open. Confirm the 323
collapses **and** how much the 579 actually shrinks. Only then convert all ~13. This A/Bs the plan's
primary lever cheaply (the API is identical) and prevents a 13-site rewrite that barely moves the
number.

**Proposed `Canvas` body** (same public API — `values, color, height, fill, grid, yDomain`):

```swift
var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
        guard values.count > 1 else { return }
        let lo = yDomain?.lowerBound ?? (values.min() ?? 0)
        let hi = yDomain?.upperBound ?? (values.max() ?? 1)
        let span = hi - lo
        let flat = span <= .ulpOfOne
        let stepX = size.width / CGFloat(values.count - 1)
        func pt(_ i: Int) -> CGPoint {
            // flat/degenerate series → center vertically (matches Swift Charts), not floor
            let norm = flat ? 0.5 : (values[i] - lo) / span
            return CGPoint(x: CGFloat(i) * stepX, y: (1 - CGFloat(norm)) * size.height)
        }
        if grid {                                   // parity: see note below
            var g = Path()
            for k in 1...3 { let y = size.height * CGFloat(k) / 4
                g.move(to: .init(x: 0, y: y)); g.addLine(to: .init(x: size.width, y: y)) }
            ctx.stroke(g, with: .color(Theme.dim.opacity(0.40)),
                       style: .init(lineWidth: 0.6, dash: [2, 3]))
        }
        var line = Path(); line.move(to: pt(0))
        for i in 1..<values.count { line.addLine(to: pt(i)) }
        var area = line
        area.addLine(to: .init(x: size.width, y: size.height))
        area.addLine(to: .init(x: 0, y: size.height)); area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.28), .clear]),
            startPoint: .zero, endPoint: .init(x: 0, y: size.height)))
        ctx.stroke(line, with: .color(color), style: .init(lineWidth: 1.2, lineJoin: .round))
    }
    .modifier(SparkSize(fill: fill, height: height))
    .accessibilityHidden(true)          // FIX 2
}
```

**Parity items to settle (review B2):**
- **Flat line:** fixed above — when `span≈0`, center at 0.5 (Swift Charts centers a degenerate
  series; a naive `span=ulpOfOne` divide would park it at the floor).
- **Grid:** current `AxisMarks(.automatic(desiredCount:4))` places lines at *nice data values*
  (count varies 3–5). The sketch draws 3 evenly-spaced interior lines. **Decision:** accept the
  even-spacing simplification (the grid is a decorative reading aid, #24) and **re-shoot the affected
  screenshots**; do not try to replicate nice-value placement in Canvas. Fix the sketch comment (it
  draws 3 lines, not 4).
- **Monotone→polyline:** acceptable at sparkline scale; add Catmull-Rom later only if a diff shows it.
- **Screenshot diff all 13 call sites** (`DashboardView.swift` 774-999 + Inspector + menu-bar
  sparklines) before landing.

### FIX 2 — `.accessibilityHidden(true)` on sparklines

Folded into FIX 1. Removes the ~43-samples/render accessibility recompute. **Owned tradeoff:**
VoiceOver loses the *trend* line but keeps the numeric value (shown as text on every card) — correct
for a decorative spark. If a11y trend matters later, re-expose via `.accessibilityLabel` with a
summary string (cheap, no view-graph). **Effort: trivial. Risk: none.**

### FIX 3 — Menu-bar glyph: skip identical re-rasterization (quantized per-glyph signature)

**Current** (`MetricBarController.swift:117-136`): `sync()` runs **every monitor tick** and does
`button.image = spec.glyph(monitor, dark)` per enabled item unconditionally (line 128). Reassigning
`button.image` forces `_updateReplicant → CALayer renderInContext` (the 73 samples) — **every tick,
even dashboard-closed** (the dominant always-on UI cost). `Entry` is a struct but
`entries[id]?.lastSig = x` mutates in place via the dict subscript's modify accessor (verified OK).

**Proposed:** each `Spec` gains a `signature: (SiliconScopeMonitor, Bool) -> String`; each `Entry`
gains `var lastSig: String?`. Re-render + reassign only when the signature changes:

```swift
if let button = entries[spec.id]?.item.button {
    let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let sig = spec.signature(monitor, dark)
    if entries[spec.id]?.lastSig != sig {
        button.image = spec.glyph(monitor, dark)
        entries[spec.id]?.lastSig = sig
    }
}
```

**⚠️ The make-or-break detail (review B3) — the signature MUST cover the *bar* glyphs, not just text:**
- **Text glyphs** (MEM/NET/SSD/SEN/battery): sign the *already-formatted display strings* + `dark`
  + the `temperatureFahrenheit` toggle (SEN). Straightforward.
- **Bar glyphs** (`ss` 5-bar `MenuBarIcon.glyph` — **on by default**; `cpu` E/P bars; `gpu` bars):
  these draw *heights*, not text. Sign the **quantized bar fractions** — each bar's normalized value
  rounded to the glyph's pixel-row resolution (e.g. `Int(frac * barHeightPx)`), computed from the
  **same normalized inputs the glyph uses**. For `gpu`, the bars are `min(1, mediaGBs/mediaPeakGBs)`
  and `min(1, aneWatts/anePeakWatts)` — the **peak denominators are moving derived state**, so the
  signature must use the *normalized fraction*, not raw watts (raw would miss a bar change when the
  peak shifts). Include `dark`.
- **Failure modes:** too coarse → stale glyph (missed redraw — the exact bug the fix must avoid);
  too fine (raw floats) → never dedupes and the fix does nothing. The 24/7 win comes precisely from
  an *idle* machine quantizing to stable bars across ticks.
- **Required: a unit test** that a known input delta (a value crossing a pixel-row, a peak shift, a
  `dark`/°F flip) flips the signature, and that a sub-pixel jitter does not.

### FIX 4 — `system_profiler` cadence (one constant, no regression)

**Current:** `PeripheralBattery.sample()` (`:79-86`) calls `ioRegistryDevices()` **every call** (fast
HID scan — Magic Mouse/keyboard, and where a newly-connected HID first appears) and merges
`bluetoothAudioDevices()` (`:125-126`), which is **already internally gated** by
`btTTL = 3` (`:73`) — that is the `system_profiler` (AirPods) spawn. The whole `sample()` is called
by `SystemSampler` every `peripheralInterval = 5 s` (`SystemSampler.swift:44`).

**⚠️ v1 was wrong** (review B4): raising `peripheralInterval` to 30 would have slowed the *cheap*
IORegistry scan and regressed new-HID appearance 5 s→30 s. The split already exists structurally.

**Proposed (durable, minimal):** **keep `peripheralInterval = 5`** (IORegistry stays responsive) and
**raise `PeripheralBattery.btTTL` 3 → 30**. Net: IORegistry every 5 s (HID % + new-device ≤5 s
unchanged); `system_profiler` spawns at most every 30 s (~6× fewer). Update both comments
(`:73` and `SystemSampler.swift:38-40`).
- AirPods first-appearance / disconnect linger becomes ≤30 s — acceptable (accessory battery isn't
  time-critical). 60 s is more aggressive; 30 s balances AirPods latency vs cost.
- *(Reference only — do NOT implement: raising `peripheralInterval` to 30. It's simpler but regresses
  cheap-scan HID latency; the durable fix is the `btTTL` bump.)*

### FIX 5 — Decouple process enumeration to a cached cadence

**Current** (`SystemSampler.swift:89`): `snapshot.processes = processes.sample()` runs **every tick**
— `proc_listallpids` ×2 + per-PID `proc_pidinfo`/`proc_pidpath`/`proc_name` (thousands of `proc_info`
traps/sec on a busy machine). Empirically small CPU (~0.05%) but pure wakeup/syscall churn.

**Proposed:** cache `[ProcessRow]` like peripherals already are (`SystemSampler.swift:101-108`),
re-sample every **~2–3 s**, reuse between ticks.
- **Correctness verified:** `ProcessSampler` normalizes CPU% by the *actual* wall-time delta
  (`nowNs &- previousTimeNs`, `ProcessSampler.swift:43-44,57`) — a longer gap just widens `wallDelta`;
  % stays correct.
- **Callout (review):** adds up to ~3 s latency to the two per-tick consumers on the main dashboard —
  **AI-runtime detection** (`SystemSampler.swift:91`) and **memory-budget** (`:94-97`): a newly
  launched `llama-server` shows a few seconds late. Acceptable; the cache must keep feeding both
  (do NOT gate on "process table visible"). Threading safe (serial off-main `sample()`; cache fields
  touched only there, like `cachedPeripherals`).

### FIX 6 — Skip the redundant `rows` re-sort (cleanup)

**Current** (`DashboardView.swift:1124-1135`): `rows` re-filters + re-sorts + `prefix(200)` each body
eval; `ProcessSampler.swift:84` already sorts desc by cpuPercent, so the default `.cpu` case re-sorts
sorted data. Sub-ms, 0× when hidden — a micro-inefficiency.

**Proposed:** skip the re-sort when `sortKey == .cpu && filter.isEmpty` (data already CPU-sorted).
**⚠️ Gate to the LIVE path only** (review): verify the **replay** path's recorded rows are also
CPU-sorted before trusting the skip there; if unsure, apply the skip only when not replaying. Do it
for cleanliness, not for the energy number.

## 4a. Considered lever — decouple render rate from sample rate (evaluate after the FIX 1 spike)

The **579** full-body re-flush fires every tick because `snapshot` is republished every second
(`SiliconScopeMonitor.swift:121`) and `DashboardState(live:)` is rebuilt in-body (`DashboardView.swift:100`).
Canvas (FIX 1) only trims the chart share of it. **Higher-leverage option:** coalesce the *dashboard*
re-evaluation to a slower rate (e.g. ~2 s) independent of the 1 Hz data sampling, or invalidate only
the chart subviews. This attacks the 579 directly.
- **Tradeoff:** the dashboard updates less often (liveness/UX) — so it's a **decision**, not a silent
  change; likely a setting or a fixed 2 s dashboard cadence while the menu bar stays 1 Hz.
- **Sequencing:** decide this **based on the FIX 1 spike** — if the spike shows the 579 still
  dominates after Canvas, implement this; if Canvas + the other fixes already close the gap, defer.
  (Arguably higher-leverage than FIX 6.)
- **Not** granular `@Observable` splitting: `snapshot` is one property replaced wholesale and
  essentially every live series changes each tick, so splitting observation spares only truly-static
  views (chip name), already cheap. (Confirmed by review.)

## 4b. Not the cause (so nobody re-chases it)

- Main-thread process **sort/filter** — ~0.01%, 0× when hidden.
- **`proc_info` enumeration** as a *CPU* driver — ~0.05% (syscall count high, CPU time low).
- **Occlusion/minimize** rendering — already paused (`WindowVisibilityObserver`, commit `8b51044`,
  `DashboardView.swift:25-58`); the 836 was measured **window-visible**, where the pause is by design
  irrelevant.
- **Per-process ANE/power** — only for the focused pid (`ProcessDetailSampler`), cheap.

## 5. Implementation order — bisectable commits (NOT one big-bang)

Landing all 6 at once makes the energy delta unattributable and a visual regression un-bisectable.

1. **Commit A — safe cleanups:** FIX 4 (one constant) + FIX 2 (one modifier) + FIX 6. ~zero risk;
   measure the always-on drop.
2. **Commit B — the lever, isolated:** FIX 1 as a **spike first** (one sparkline → profile → confirm
   the 579 shrinks), then convert all 13 with parity screenshots. Isolated so a visual regression is
   bisectable. *(If the spike shows 579 still dominates → do §4a next.)*
3. **Commit C:** FIX 3 with the quantized per-glyph signature + the unit test.
4. **Commit D:** FIX 5.

Update each edited file's header `Updated:` date; English comments only. **Hold the release until
after the before→after measurement** (matches "don't over-release / measure first").

## 6. Verification protocol (the Energy-Impact delta is the proof)

1. **Baseline (captured):** Activity Monitor → Energy → SiliconScope ≈ **836 / 549**;
   `sample <pid> 10` main-thread work ≈ 99% rendering (579 + 323 + 73 + 43).
2. **After each commit**, same Mac, same window state:
   - **Primary proof:** leave it running, re-check **Activity Monitor Energy Impact** — target: same
     order of magnitude as a comparable live monitor, not ~200×. (The `sample` CPU buckets under-count
     GPU, so Energy Impact is the real number.)
   - `sample <pid> 10` — after FIX 1 the 323 collapses + 43 gone; after §4a the 579 shrinks.
   - `ps -p <pid> -o %cpu` over ~30 s — steady-state CPU below the ~24% baseline.
3. **Menu-bar-only** (dashboard closed): confirm FIX 3 + FIX 4 shrink the `_updateReplicant` and
   `runSystemProfiler` buckets.
4. **Parity:** dashboard graphs look right (screenshot diff), values/CPU% still correct, Inspector +
   menu-bar dropdowns still render, a newly-connected HID still appears ≤5 s.

## 7. Code map (for the implementer)

- `Sources/SiliconScope/Theme.swift:249-291` — `Sparkline` (FIX 1, 2).
- `Sources/SiliconScope/MetricBarController.swift` — `Spec`/`Entry` at **lines 25-32**; `sync()` at
  **117-136** (FIX 3).
- `Sources/SiliconScope/MenuBarMetric.swift` / `MenuBarIcon` — the bar-glyph renderers (FIX 3 signature
  must mirror their normalized inputs, incl. `mediaPeakGBs`/`anePeakWatts`).
- `Sources/SiliconScopeCore/SystemSampler.swift:38-108` — orchestration; `peripheralInterval` :44
  (keep 5); process line :89 (FIX 5); the four delta samplers run concurrently in a `DispatchGroup`
  (67-76), blocking ~one `interval` off-main.
- `Sources/SiliconScopeCore/PeripheralBattery.swift:70-127` — `sample()` merges IORegistry (every
  call) + `bluetoothAudioDevices()` (btTTL-gated `system_profiler`); `btTTL` :73 (FIX 4: 3→30).
- `Sources/SiliconScopeCore/ProcessSampler.swift:42-84` — per-pid syscalls; wall-time-normalized CPU%
  (FIX 5 correctness).
- `Sources/SiliconScope/DashboardView.swift:19-110` — `WindowVisibilityObserver` + off-screen freeze
  (occlusion already handled — do not duplicate); `:100` `DashboardState(live:)` rebuild (§4a);
  `:1124-1135` — `rows` (FIX 6).
- `Sources/SiliconScope/SiliconScopeMonitor.swift:96-141` — the 1 Hz loop; `:121` snapshot publish;
  `:136` `MetricBarController.shared.sync` every tick.
