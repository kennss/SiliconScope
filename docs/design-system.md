# SiliconScope — Design System Pass

> Design for closing **#19 (app zoom / scale-aware pass)** and **#27 (menu-bar visualisation
> consistency)** with one system rather than two patches.
>
> **Status (2026-07-27): the pass is complete — phases 0 through 5 are shipped in the working
> tree, closing #19, #27 and the "make it read like an instrument" requests.** Each build
> corrected its own section: 4a corrected §4.2 (a mode needs a renderer, not only a series), 4b
> corrected §4.6 (a hardcoded label width was clipping shipped glyphs at every zoom step above
> 100 %), and 5 corrected §5.2 (see the correction there).
>
> **v2 (2026-07-26, decision D1 added 2026-07-27)** — v1 was audited against the source twice
> (fact-check + adversarial design review) and failed on five blockers. This revision records
> what was wrong, because the failures are the useful part: they are all cases where the obvious
> design contradicts code that already exists for a documented reason. Settled decisions are
> collected in §7. In-app text stays English.
>
> iStat Menus 7 was studied for **structure**, deliberately not for **look** — see §2.

---

## 1. Diagnosis — measured

Census over `Sources/SiliconScope/*.swift` (2026-07-26). **v1 undercounted; these are corrected.**

| Axis | Finding |
|---|---|
| SwiftUI `.system(size:)` | **150 sites, 13 values** (7 … 15). `11`×55, `10.5`×26, `10`×21, `9.5`×15, `9`×12, `12`×11, rest ≤2 |
| AppKit `NSFont.systemFont(ofSize:)` | **4 more sites, 2 more values** — 6.5 (`MenuBarMetric.swift:27`), 8.5 (`:107`), 9 (`:140`), 7.5 (`MenuBarIcon.swift:99`) → **154 sites / 15 values** total |
| Semantic fonts (`.caption`, `.callout`, …) | **34 sites** in Fleet / Replay / Record / AddMachine / Settings / sidebar — a *second, separate* type system (§3.5) |
| Concentration | DashboardView 66 + MenuBarMetric 51 = 117 / 150 (78 %) |
| Padding | 16 distinct literals (1…24) |
| Stack spacing | 14 distinct literals **including `0` ×5**, which is load-bearing (`StackedBar` `Theme.swift:207`, `MenuStackedBar` `MenuBarMetric.swift:286`) |
| Corner radius | 7 distinct (2, 3, 6, 7, 8, 9, 10) + AppKit 0.8/1.2/2 |
| **Fixed layout dimensions** | **39 fixed `frame(width:)` + 8 fixed/min heights in `DashboardView` alone** — §3.4 |

`Theme.swift` already tokenises **colour** (`bg/panel/border/text/dim/faint/accent`, `heat(_:)`)
and provides atoms (`Card`, `Bar`, `StackedBar`, `LegendRow`, `KV`, `Sparkline`,
`PopoverButtonStyle`). Type, space and layout are untokenised.

### 1.1 The menu-bar finding

`MenuBarGlyph` already implements `drawStackedLabel` / `histogram` / `bars` / `twoLine` /
`battery`. **`MenuBarGlyph.histogram` is dead** — exhaustively verified across all 5 targets,
tests and `agent/`; it is a `static func` on a non-`@objc` enum, so dynamic reach is impossible.

**A second dead path:** `struct MenuBarIcon: View` (`MenuBarIcon.swift:31`) is never
instantiated. There is **no `MenuBarExtra` scene in the app** (`SiliconScopeApp.swift:77-80`
declares only `mainWindow` + `Settings`); the combined "SS" item is an `NSStatusItem` like the
rest. Consequently `closeCombinedPopover()` (`MetricBarController.swift:213-222`) hunts for a
`MenuBarExtraWindow` that never exists — dead — and the headers of `MenuBarMetric.swift:11-12`
and `MenuBarIcon.swift:6` are stale.

`MetricBarController.specs` is a static array of 8 `Spec`s, each with **five** members
(`id`, `key`, `glyph`, `signature`, `dropdown` — `MetricBarController.swift:25-33`). `entries`
is `[String: Entry]` keyed on `spec.id`, so **1 metric : 1 menu-bar item is structurally
enforced**, and each `Spec` bakes in one render mode plus one data selection.

**#27 is therefore a binding-layer problem, not a rendering problem.**

---

## 2. Principles

Adopt iStat's **structure**; reject its **look**. SiliconScope's identity — monospaced, dark,
dense instrument panel — is fixed in `CLAUDE.md` preamble (line 4) and the §2 decisions table
(line 26: *"디자인 언어만 계승, 코드 포크 아님"*).

**Adopt:** 1:N metric→item model · separate menu-bar vs dropdown settings · two-step density ·
theme = palette tokens over an invariant layout · accent-coloured section headers ·
state-dependent modes.

**Reject — explicitly out of scope:** ❌ ring/donut gauges (lower density, fights the monospaced
grid; the existing fill bar is *more* correct here) · ❌ light default · ❌ non-monospaced ·
❌ redesigning Combined mode.

**Non-goals (revised).** No change to what is measured or how it reads. `SiliconScopeCore`
sampling logic is untouched — but **adding `History` series and moving `MenuBarItemConfig` +
its migration into Core is explicitly allowed**, because Core is the only unit-testable target
(`MenuBarSignature` is already there, with tests). v1's blanket "nothing in Core" contradicted
its own §4.

---

## 3. Part A — Type, space and layout (#19)

### 3.1 Roles are semantic, and two-dimensional

**v1 was wrong**: it derived roles from *sizes*. Of the 15 sites at 9.5 pt, exactly **one** is a
section header (`Theme.swift:134`); three are SF Symbols and the rest are footnotes (IP address
`MenuBarMetric.swift:612`, "Connected" `:616`, "Peak ↓/↑" `:626,629`, "tap to inspect"
`DashboardView.swift:1204`). Mapping by size would put semibold + 1.5 tracking on an IP address.

Meanwhile the **real headers are scattered across five sizes with different tracking**:

| Role | Current |
|---|---|
| Card title | 9.5 semibold, tracking 1.5, faint (`Theme.swift:134`) |
| SubLabel (2nd level *inside* a card) | 9 semibold, tracking 1.2, faint (`DashboardView.swift:1063`) |
| Dropdown section header | 10 bold, tracking 1, **accent**, centered (`MenuBarMetric.swift:368`) |
| Sparkline label | 8.5 semibold, tracking 0.5 (`DashboardView.swift:998`) |
| Table header | 9 semibold (`DashboardView.swift:1216`) |

Card title (9.5) and SubLabel (9) are **vertically adjacent inside the same card**
(`MemoryBandwidthCard` `:910`→`:922`/`:961`; `NetworkDiskCard` `:1022`→`:1033`/`:1044`).
Collapsing both into one role destroys a two-level hierarchy that currently works.

**Second dimension: weight is not a function of size.** Real distribution at 11 pt: 39 regular,
12 medium, 3 semibold, 1 bold. `MenuKV` deliberately uses label regular / value **medium**
(`MenuBarMetric.swift:274,276`) — the same pattern in `MenuLegendRow` `:304,306`,
`CPUMenuDropdown.kv` `:433,435`, `MenuBarView.topProcesses` `:186,192`. A single-axis `.body`
that bakes `regular` **erases value emphasis in every dropdown**.

So the scale is `(role, emphasis)`:

| Role | Size | Purpose |
|---|---|---|
| `.sectionMajor` | 9.5 semibold, tracking 1.5 | Card titles |
| `.sectionMinor` | 9 semibold, tracking 1.2 | Sub-headers inside a card, table headers |
| `.sectionMenu` | 10 bold, tracking 1.0, accent | Dropdown section headers |
| `.caption` | 9 | Footnotes, axis labels |
| `.detail` | 10.5 | Secondary value |
| `.body` | 11 | Default row |
| `.emphasis` | 12 | Buttons, promoted values |
| `.headline` | 14 | The one headline number per card |

with `emphasis: .plain | .strong` selecting regular vs medium/semibold per role. **SF Symbol
point sizes are not typography** and stay out of the scale — ~20 of the 150 counted sites are
`Image(systemName:).font(.system(size:))` and get a separate `Icon.*` token set.

### 3.2 Space and radius — tuned to modal values, not to round numbers

v1 invented `Space.card = 9`, a value that **occurs zero times** (`spacing: 8` ×16,
`spacing: 10` ×5). Tokens take the **modal** value of their cluster so the common case doesn't
move:

| Token | Value | Rationale |
|---|---|---|
| `Space.none` | **0** | required exactly-0 (`StackedBar`, `MenuStackedBar`) — v1 omitted it |
| `Space.hair` | 2 | ×16 |
| `Space.tight` | 4 | ×12 |
| `Space.row` | 6 | ×35 — dominant |
| `Space.card` | **8** | ×16 (not 9) |
| `Space.section` | 12 | ×7 |
| `Space.page` | 20 | ×3 |
| `Radius.control` | 7 | `PopoverButtonStyle` |
| `Radius.card` | 9 | `Card` |
| `Radius.swatch` | **2** | legend swatches — **not** `height/2`; v1's pill rule would turn `LegendRow`'s 8×8 square (`Theme.swift:226`) into a circle |
| `Radius.pill` | height/2 | capsules only |

Values with a documented intent are **pinned, not collapsed** — e.g. `Card`'s
`.padding(.top, 14)` is commented "~one Bar tall" (`Theme.swift:147`) and keeps its own token.

### 3.3 Scale delivery — v1's mechanism does not work

**v1 proposed an `EnvironmentKey` injected at `SiliconScopeRootView`. It reaches one surface
out of eleven.**

- The 8 dropdowns are built with `NSHostingController(rootView:)`
  (`MetricBarController.swift:187`) — **each is its own SwiftUI environment root**. Nothing
  injected upstream arrives.
- `Settings { SettingsView() }` is a **sibling Scene** of `mainWindow`
  (`SiliconScopeApp.swift:77-80`). Scenes do not inherit each other's environment.
- Worse, `makeEntry` runs only when `entries[spec.id] == nil` (`:159`), so a hosting controller
  **lives for the whole process** and its `rootView` is never reassigned. Any scalar captured at
  construction is permanently stale.
- Only the dashboard tree (and `InspectorView`, presented as a `.sheet`,
  `DashboardView.swift:100`) would have received it.

**Corrected design — the store is the source of truth, every root reads it:**

```
ui.zoom     Double  0.9 / 1.0 / 1.15 / 1.3     ⌘− ⌘0 ⌘+   (0.85 dropped — §3.6)
ui.density  enum    .standard | .compact       spacing only, never type
```

- Every SwiftUI **root** (`DashboardView`, each `*MenuDropdown`, `MenuBarView`, `SettingsView`,
  Fleet views) reads `@AppStorage("ui.zoom")` itself. `@AppStorage` is KVO-backed, so it updates
  live *inside* a hosting root with no controller recreation.
- `EnvironmentKey` remains only as call-site sugar **within** the dashboard subtree.
- AppKit rasterisers stay **pure**: `MenuBarGlyph.*` take scale as a parameter. This matches the
  established pattern — `temperatureFahrenheit` is read in the *controller*
  (`MetricBarController.swift:147`) and passed in (`:121`), never read inside the glyph. v1's
  "glyphs read UserDefaults directly" would break their testability.

⚠️ **Signature invalidation.** `sync()` re-rasterises only when `spec.signature(monitor, dark)`
changes (`:168-172`); `lastSig` resets only on create/destroy. **Scale must be folded into all 8
signatures** or glyphs stay stale after a zoom change. Two further consequences v1 missed:
`MenuBarSignature.barRows = 36` (`SiliconScopeCore/MenuBarSignature.swift:21`) is a constant tied
to the 18 pt glyph height and must scale with it, and `MenuBarSignature.text()` has no `extra:`
slot the way `bars()` does.

`scaleEffect` is rejected: it upscales the rendered bitmap, blurring text and smearing hairlines.

### 3.4 Phase 0 — the layout axis is what actually blocks zoom

Type is not the binding constraint. **Fixed geometry is.**

- **8 fixed/min heights** in `DashboardView` (`:187, 196, 198, 226, 238, 254, 262, 952`).
- **39 fixed `frame(width:)`** — process table columns (`:1211-1213, 1222-1227`), sensor value 44
  + bar 60 (`MenuBarMetric.swift:779,783`), fan 70 (`:798`), MHz 64 (`:420`), seven dropdowns at
  260, `MenuBarView` 270/340, Inspector 460×640, Settings 400×710.

The decisive evidence is a comment already in the code (`DashboardView.swift:248-253`):

> *"The dense Memory column's intrinsic height (~188pt…) **can exceed a fixed 176 by a few
> points** under some macOS versions' text metrics and spill into the CPU card (#25, a re-run of
> #23)."*

**The layout is already at its margin at zoom 1.0.** Zoom 1.15 re-triggers #23/#25 verbatim, and
even §3.2's spacing normalisation eats into that margin. Text inside the 39 fixed widths would
truncate to `…`.

→ **New Phase 0:** census and tokenise `Layout` (row heights, popover widths, column widths) as
scale functions. Zoom cannot ship before this.

⚠️ **Correction (phase 2, 2026-07-27): "convert the process table to `Grid`" was wrong and has
been dropped.** `Grid` cannot do the job here for two independent reasons:
1. The table's header sits **outside** the `ScrollView` while its rows are **inside** it
   (`DashboardView.swift:1210` vs `:1218`). A `Grid` shares column widths only among its own
   rows, so it cannot align a header across that boundary.
2. `Grid` is **not lazy**. The rows live in a `LazyVStack` precisely so hundreds of processes
   are virtualised — abandoning that contradicts `docs/energy-optimization.md`, which is the
   reason the list is lazy in the first place.

The columns therefore stay fixed-width, but are now `Layout.Column.*` tokens
(`processPID` / `processCPU` / `processMemory`), so phase 3 scales them with `ui.zoom` instead of
truncating. Same outcome, without losing virtualisation.

### 3.5 Decision — SiliconScope does not track Dynamic Type; `ui.zoom` is the only scale axis

`.system(size:)` (150 sites) ignores the OS "Larger Text" setting entirely. The **34 semantic
font sites** — `FleetOverviewView` 7, `FleetMachineDetailView` 7, `LinuxServerView` 5,
`AddMachineSheet` 5, `SiliconScopeRootView` sidebar 4, `RecordBar` 3, `ReplayBar` 2,
`SettingsView` 1 — do respond. v1's census omitted all of them, and its phase table's
"others (4)" counted only `size:` literals.

Left alone, **zoom enlarges the dashboard while the Fleet views, sidebar and Replay/Record bars
stay fixed** — and Replay/Record are attached to the dashboard via `safeAreaInset`
(`DashboardView.swift:107-114`), so the mismatch is visible side by side in one window.

**DECIDED (2026-07-27): `ui.zoom` is the only scale axis. Dynamic Type is not tracked.**

The alternative — `.system(size:relativeTo:)` on all 150 sites — was rejected because **it hands
an unbounded external multiplier to a layout that is already at its margin**. §3.4 quotes the
existing code comment: the Memory column can *already* exceed its fixed 176 pt "under some macOS
versions' text metrics" (#25, a re-run of #23). Under Dynamic Type a user who enlarges system
text re-triggers that overflow having never touched a SiliconScope setting, and nothing in the
app's own UI explains why. `ui.zoom` keeps the range app-owned, clamped and testable — Phase 0
tokenises `Layout` against *that specific range*.

Three supporting reasons:
- **The menu bar cannot follow anyway.** macOS fixes the menu-bar height at 18 pt
  (`MenuBarMetric.swift:22`), so glyphs grow only wider. Tracking Dynamic Type would create a
  *third* inconsistency (dashboard scales, Fleet scales, menu bar cannot). §3.6 already caps
  glyph scale separately.
- **It is more work and it is judgement-heavy.** `relativeTo:` needs a `TextStyle` chosen per
  site, and ~20 of the 150 are SF Symbol point sizes where `TextStyle` does not apply.
- **Density is the product.** A dense monospaced instrument panel deriving from btop is not a
  fluid-layout product; §2 fixes that identity.

**This is a decision, not neglect — so it carries four requirements:**
1. **`ui.zoom` must be discoverable**: a Settings control is mandatory, not just ⌘+/⌘−. In
   `.accessory` mode (which `SettingsView.swift:61` actively recommends) there is no menu bar at
   all — see §3.6.
2. **The ceiling must be genuinely useful.** 1.3 is provisional; the real limit is whatever the
   Phase 0 `Layout` tokens are measured to survive. Decide it from that measurement, not now.
3. **The 34 semantic-font sites are converted to tokens** in phase 2, so the app stops having two
   type systems.
4. **The reason is stated publicly** when #19 is closed. The accessibility angle was raised by the
   reporter and acknowledged; the honest answer is that the app provides a bounded scale axis it
   can guarantee instead of accepting an unbounded one it cannot survive — the same
   label-the-limit posture as the #30 reply.

*Optional refinement, deferred:* seed `ui.zoom`'s **default** from the OS accessibility text
setting (so a user with Larger Text starts enlarged), with the user's own value winning
thereafter. This keeps the range app-owned while recovering most of the accessibility benefit.
**Not adopted yet** — whether that setting is reliably readable on macOS is unverified, and this
document does not encode unverified API behaviour. Verify before implementing; if it is not
readable, plain `ui.zoom` stands.

### 3.6 Zoom range and reachability

- Floor is **0.9**, not 0.85: `.caption` (9) × 0.85 = 7.65 pt monospaced, and a 7 pt chevron
  (`DashboardView.swift:1288`) → 5.95 pt. Roles additionally clamp to a per-role minimum.
- **⌘+/⌘−/⌘0 are unreachable in the app's recommended configuration.** With
  `showDockIcon = false` the app is `.accessory` (`SiliconScopeApp.swift:57-60`) and has no menu
  bar — and `SettingsView.swift:61` actively recommends that mode. Zoom therefore **must** also
  be a control in Settings; the keyboard shortcut is an accelerator, not the interface.
- Glyph zoom is bounded differently: menu-bar height is fixed by macOS (18 pt,
  `MenuBarMetric.swift:22`), so glyphs can only grow **wider** — which collides with Part B
  putting more items on a notched Mac. Glyph scale is capped (~1.15) and tracked separately.

---

## 4. Part B — Menu-bar instance model (#27)

### 4.1 Model — four axes, not three

v1's `(metric, mode, channel)` cannot express three of the eight existing specs.

```swift
struct MenuBarItemConfig: Codable, Identifiable {
    let id: UUID
    var metric: MetricKind
    var mode: GlyphMode
    var channels: [DataChannel]      // ARRAY — arity is constrained by `mode`
}
```

- **`channels` must be a list.** The GPU spec composes **three heterogeneous metrics with
  different normalisers** — GPU usage, media GB/s ÷ `mediaPeakGBs`, ANE W ÷ `anePeakWatts`
  (`MetricBarController.swift:41-45`). Arity is mode-dependent: `bars` = N, `twoLine` = exactly
  2, `value` = 1. The mode × channel cartesian product is **not** well-formed.
- **Each `DataChannel` owns its own `(normaliser, label, reserveTemplate)`.** The missing fourth
  axis in v1 is `reserveValue` — the worst-case width template (`"999.9 GB"` `:84,:109`,
  `"999 MB"` `:96`, `"99°"` `:123`). Without it **the item's width jitters every second and
  shoves every item to its left**.
- **Sensors needs a runtime-conditional channel.** `sensorGlyphInputs` picks
  `gpuCelsius > 0 ? ("G", gpu) : ("B", battery)` (`:146-152`) — a static enum cannot express it;
  the channel resolves at sample time.
- **`.combined` is an explicit exception, not a mode.** `MenuBarIcon.glyph`
  (`MenuBarIcon.swift:82-133`) is not `MenuBarGlyph.bars`: different label font (7.5 bold vs 6.5
  bold), its own `barColors` table, plus alert/blink overrides. It keeps its dedicated renderer
  and is documented as outside the three axes rather than pretended into them.

### 4.2 `supportedModes` must be derived from data that exists

v1 promised modes with no backing series. The available history is
`MetricsEngine.History` (`SiliconScopeCore/MetricsEngine.swift:21-36`): soc, pCPU, eCPU, gpu,
gpuMem, ane(W), media(GB/s), bandwidth(GB/s), dieTemp, memory(GB), memFraction, netDown/Up(B/s),
diskRead/Write(B/s).

- **No series exists** for disk *space*, per-sensor temperature, or battery %.
- Rate series are **not 0…1**, and `histogram` only clamps (`MenuBarMetric.swift:60`) — it has no
  auto-scaler.

| Family | `supportedModes` | Note |
|---|---|---|
| CPU, GPU, Memory | `bars`, `histogram`, `twoLine`, `value` | history exists and is 0…1 |
| Network, Disk I/O, Bandwidth | `twoLine`, `value` | `histogram` **deferred** until an auto-scaling normaliser exists |
| Disk space, Sensors, Battery | `twoLine`, `value`, `icon` | no history series |

A fill bar of "MB/s" stays impossible — there is no ceiling to fill against, so `bars` is never
offered for rate metrics. The type system enforces the product's no-invented-numbers rule.

#### ⚠️ Correction found in 4a — the rule applies to RENDERERS too, not only to series

The table above checks each mode against the *data* that exists, and stops there. Building the
renderer showed the second half of the same rule: `value` was offered by every metric, and no
renderer for it existed. `MenuBarGlyph` had `bars`, `histogram`, `twoLine` and `battery` — four
renderers for five promised modes. Every migrated item happened to land on one of the four, so the
gap was invisible until a `GlyphMode` was rendered generically instead of per metric.

Fixed by adding `MenuBarGlyph.oneLine` (the one-row form of `twoLine`, on its own `Glyph.singleValue`
size token — a single row owns the full 18 pt height, so reusing the two-row size wastes half of it)
rather than by retiring `value` from `supportedModes`: `value` is the narrowest way to show a metric,
which is exactly what a full menu bar needs.

**`supportedModes` must therefore be backed by BOTH a series and a renderer.** `histogram` for rate
metrics is still deferred — that one is missing a normaliser, not a renderer.

### 4.3 Ordering — macOS owns it

`order: Int` is **unenforceable**. Users ⌘-drag status items and macOS persists position per
`NSStatusItem.autosaveName`; there is no API to set left-to-right order. The code sets no
`autosaveName` (`:183`), so the comment *"First so it sits leftmost"* (`:57`) **is already
false** — items attach in the order their toggles were switched on.

→ Drop `order`. Set `autosaveName = "ss.item.<uuid>"` per instance and treat the OS-persisted
position as truth. Settings says "reorder by ⌘-dragging in the menu bar" instead of lying with a
list.

### 4.4 Migration — the legacy Bools are *written* from 16 places

The eight `menubar.*` Bools are not read-only config. **Seven dashboard card pins write them**
via `@AppStorage` (`DashboardView.swift:332, 800, 844, 884, 1016, 1017, 1077`), through
`Card(menuBarPin:)` / `MenuBarPin` (`Theme.swift:111,138`), plus `SettingsView.swift:31-38`.
`SettingsView.swift:29-30` documents the coupling. v1's "stop reading the legacy keys" would turn
**every card pin into a dead switch**.

**`MenuBarPin` semantics under 1:N (undefined in v1, and it is the most-touched control):**
- ON ⟺ this metric has ≥ 1 instance (derived state, not stored).
- Turning it **on** appends one instance in the metric's default mode.
- Turning it **off** removes *all* instances of that metric.

**Migration:** guard on a stored **schema version**, not merely on the presence of
`menubar.items` — presence-only means a downgrade → toggle → re-upgrade silently discards the
interim change. Synthesise instances from the legacy Bools using each metric's *current* mode,
then remove all legacy **write** paths and freeze the keys as a read-only snapshot. Release notes
must state that downgrading restores the upgrade-time layout.

### 4.5 Per-tick cost — Part B must not regress the always-on regime

`sync()` runs every tick (`SiliconScopeMonitor.swift:135`) and today is a static 8-element walk
plus 8 `UserDefaults.bool` reads. Decoding `menubar.items` JSON every tick would put a
`JSONDecoder` and array allocation on the 1 Hz path **even with the dashboard closed** — exactly
what `docs/energy-optimization.md` FIX 3/4 defend.

→ Cache the decoded config; invalidate only on explicit store mutation. Separately, make each
popover's `contentViewController` **lazy** — `makeEntry` builds it eagerly today (`:187`), so up
to 8 hosting controllers are resident before any dropdown is opened, and two instances of one
metric would create two live subscribers.

### 4.6 What this unlocks

`MenuBarGlyph.histogram` becomes reachable. #27's request becomes a setting. Future metric
requests become configuration.

**The `labelW` estimate was wrong, and not only in `histogram`.** All four renderers reserved a
hardcoded 7 or 8 pt for the stacked label while the draw block positioned content at its REAL
width. `Glyph.stackedLabel` scales with zoom, so measuring it gives 7.0 pt for "MEM" at 100 %
(exactly the reserve, zero margin), 8 pt at 125 % and 10 pt at 150 % — the value column was being
clipped at every zoom step above 100 %, in shipped `twoLine` glyphs, not only in the unreachable
one. Replaced by `MenuBarGlyph.stackedLabelWidth(_:)`, measured from the same font the label is
drawn with.

---

## 5. Part C — Visual grammar

Five items, corrected against the source. All are hierarchy problems; none needs ring gauges.

1. **Card titles are all one grey** — `Theme.swift:133-136` renders every title in `Theme.faint`
   across 8 dashboard cards + 7 in `InspectorView`. → accent at reduced opacity.
   ⚠️ **Dropdowns already do this**: `MenuSectionHeader` is already `Theme.accent`
   (`MenuBarMetric.swift:369`). This fix applies to the dashboard only.

2. **Values are typeset *below* their labels.** v1 said "same size"; in fact `Bar` draws label 11
   / detail **10.5** (`Theme.swift:181,185`), so `961 MHz` and `2.7 W` are a step *smaller* than
   their labels — the problem is worse than stated. Only a few values are promoted to 12 medium
   (`DashboardView.swift:344, 351, 922`). → one `.headline` per card.

   #### ⚠️ Correction found in 5 — swap the two sizes; do not raise both
   `KV` and `LegendRow` *already* have the right grammar (key `dim`, value `text`, one size).
   **`Bar` was the only outlier**, so the fix is to match them, not to invent a new hierarchy.
   Raising the detail to `.body` alongside an 11 pt label widened every row, and the Disk column's
   `free 1.61 TB / 4.00 TB` immediately wrapped to two lines. Shipped instead: label → `.detail`
   + `dim`, value → `.body` + `text` — the row's total width demand is unchanged. The disk string
   also became `2.39 / 4.00 TB` (`formatBytesOfTotal`), one unit for a part and its whole, the
   same shape the Memory card already used.

   **"One `.headline` per card" applies only where a single primary reading already exists** — the
   Memory card's `37.4 / 64 GB`. CPU, GPU, Network & Disk and Sensors have no one number that
   summarises them, and promoting a synthesised total would add a reading rather than rank the
   existing ones. Typography ranks what is there; it does not create data.

3. **One chart primitive, four ad-hoc configurations.** v1 claimed four grammars; there is
   exactly one — `Sparkline` (`Theme.swift:248-307`) unconditionally draws area **and** line
   (`:296-300`), with no line-only mode. The defect is call-site configuration:
   `(fill:true, grid:true)`, `(fill:true)`, `(height:22)`, `LabeledSparkline(yDomain:)`.
   → keep line+area (btop identity; do **not** adopt iStat's histogram) and expose exactly two
   named roles, `.trend` and `.inline`. No raw `fill:`/`grid:`/`yDomain:` at call sites.

4. **Colour encoding is implicit, not overloaded.** `Bar` falls through
   `color ?? Theme.heat(value)` (`Theme.swift:191`) — but only **2 of 9** call sites rely on it
   (`DashboardView.swift:962` Bandwidth Total, `:1047` Disk Used). v1's rule
   ("state never fills") would **forbid correct encodings**:
   - Memory pressure (`:949`, `MenuBarMetric.swift:553`) — the bar's identity *is* its state;
     there is no alternative identity colour, and green/amber/red fill is the platform convention.
   - Sensor temperature (`MenuBarMetric.swift:782`, `DashboardView.swift:1142,1155`) — a 5 pt
     capsule **cannot** carry a legible border.
   - Battery low (`MenuBarMetric.swift:170-173`) — the 18 pt glyph's badge slot is already used
     by bolt/plug, so the rule would delete the low-power warning.
   - Disk Used (`:1047`) — heat is *right*; disks have no identity colour.
   - Bandwidth Total (`:962`) — heat is *wrong*, but because `bandwidthPeakGBs` is an observed
     rolling peak that saturates against itself. **That is a normalisation bug, not a colour
     rule.**

   → **Revised rule: a `Bar` must not change encoding based on whether an argument was passed.**
   Delete the `??` fall-through; the call site declares `Bar(encoding: .identity(Color))` or
   `.state(Double)`. Also name the **third channel** v1 ignored: `heat` is used as *text
   foreground* in 15+ places (`DashboardView.swift:1225`, `MenuBarMetric.swift:404,779`,
   `MenuBarView.swift:193`). Define all three — fill, border, text.

5. **SENSORS dead space — but not by changing card heights.** v1's diagnosis ("three rows") was
   wrong: `SensorsCard` has its own `ScrollView` (`DashboardView.swift:1116`) over up to five
   runtime `SensorCategory` groups. And its remedy is a **documented regression**:
   `DashboardView.swift:260-262` pins `.frame(height: 196)` precisely because *"minHeight lets
   the whole list expand and balloons the window"* — the fix for #23/#25/#16.
   → Fill the space with `Card`'s existing `graph:` slot (`Theme.swift:118-147`, built for #24):
   give `SensorsCard` a `dieTemp` fill-graph. **Row-height policy is not touched.**

---

## 6. Migration order

| Phase | Work | Visual change | Risk |
|---|---|---|---|
| **0** | `Layout` census + token definition only (8 heights, 39 widths) | **none — genuinely** | low |
| **1** | `Theme.Type` / `Space` / `Radius` / `Icon`; convert the 8 atom sites in `Theme.swift` | none | low |
| **2** ✅ | Replace remaining literals: 154 SwiftUI fonts, 4 AppKit glyph fonts, 34 semantic fonts (D1 req. 3, D3), ~100 spacing/padding/radius, all fixed widths and heights. `Grid` conversion dropped — see §3.4 correction | **intentional normalisation — done** | medium |
| **3** ✅ | Scale-aware tokens; View-menu ⌘+/⌘=/⌘−/⌘0 **and Settings controls** (D1 req. 1); scale folded into all 8 glyph signatures. Range measured → D4. `barRows` needs no change: the menu-bar height never scales, so a bar still spans 36 pixel rows — zoom changes glyph *width* | zoom works | medium |
| **4a** ✅ | `MenuBarItemConfig` + `MenuBarItemStore` + migration, **in Core, unit-tested** (19 tests); the renderer became data-driven (`MenuBarItemRenderer`) and all 15 legacy **write** paths were removed. `GlyphMode.value` needed a renderer that did not exist — added as `MenuBarGlyph.oneLine`, see §4.2 correction | **none — verified A/B** | medium |
| **4b** ✅ | Settings UI: add / duplicate / delete / configure instances. Channel controls are **derived from `GlyphMode.arity`** — fixed arity becomes N ordered pickers, a range becomes a bounded toggle set — so no metric is special-cased and a new mode needs no new UI | none by default | **high — the real work** |
| **5** ✅ | Visual grammar §5 — accent card titles, row hierarchy inverted, `Sparkline` reduced to two roles with the axis on the data, `Bar(encoding:)` replacing the `??` fall-through, Sensors trend in the graph slot | **intended** | medium |

### ⚠️ v1's "phases 1–2 are provably no-ops" was false

Applying v1's tables would have moved **107 call sites**: type 30, stack spacing 48, padding 19,
radius 10 — plus ~47 weight/tracking changes. §3.1–3.2's modal-value tuning removes most of it,
but **not all**, and there is **no UI test target** with which to prove a no-op (only
`SiliconScopeCoreTests` exists). Phase 2 is therefore declared an **intentional normalisation
with a screenshot re-baseline**, not a silent refactor. That is also why 4a puts the migration
logic in Core: it is the only part of Part B that *can* be tested.

`#19` closes at phase 3, `#27` at phase 4b, and phase 5 is what the "make it pretty like iStat
Menus" requests were actually asking for.

---

## 7. Decisions and open questions

### Decided
- **D1 · Dynamic Type (§3.5, 2026-07-27)** — not tracked. `ui.zoom` is the only scale axis,
  because the layout is already at its margin and Dynamic Type is an unbounded external input.
  Carries four requirements: Settings control mandatory, ceiling set from Phase 0 measurement,
  the 34 semantic sites converted in phase 2, and the reason stated publicly on #19.
- **D2 · Verification (2026-07-27)** — **screenshot baseline**, captured by running the app
  before and after each phase (dashboard, every dropdown, Settings, Fleet views). No UI test
  target is added. Consequence to accept knowingly: this catches regressions *in this pass* but
  does not prevent future ones — §7 Q6 keeps the harness question alive rather than closing it.
- **D3 · One type system (2026-07-27)** — Fleet views, Replay/Record bars and the sidebar are
  **converted to the same monospaced tokens** as the dashboard (phase 2). The app stops having
  two type systems, and `ui.zoom` covers every surface. Their present look is treated as an
  artefact of v4.0.0's pace, not as an intentional distinction; **their appearance will visibly
  change**, which D2's baseline is expected to show.

- **D4 · Zoom range (2026-07-27, measured)** — **0.9 / 1.0 / 1.15 / 1.3**, with a per-role
  minimum point size so the smallest step cannot make a role illegible. Measured on the real app
  at both extremes: at **1.3** the dense Memory column still does not spill (it is a `minHeight`
  row, so content and container scale together and #25 is structurally impossible), and the
  window's scaled `mainWindowMin` grows with it. At **0.9** the layout is *better* than at 1.0 for
  a 640 pt window — "Compressed" stops wrapping and process names stop truncating. Menu-bar glyph
  scale is capped separately at 1.15, since macOS fixes the menu-bar height and a glyph can only
  grow wider.

### Open
1. ~~**Zoom ceiling**~~ — answered by D4.
2. **Seed zoom from the OS accessibility setting?** (§3.5, deferred) — needs verification that
   the setting is reliably readable on macOS before it can be designed in.
3. **Accent palette count** — one dark accent set, or three or four?
4. **Notch overflow** — macOS silently hides status items that don't fit, with no detection API.
   Warn at N items, or leave it?
5. **Dead code** — remove `MenuBarIcon: View`, `closeCombinedPopover()` and the stale headers
   now, or during phase 4?
6. **Snapshot-test harness** — D2 deliberately ships this pass without one. Worth adding
   afterwards so the normalised layout stays normalised?

### Found during design — not part of this pass
- **Bandwidth Total normalisation bug.** `DashboardView.swift:962` divides by
  `bandwidthPeakGBs`, an *observed rolling peak*, so the bar saturates against itself and reads
  near-red almost always. This is a normalisation defect, not a design-system issue; fix it
  separately rather than folding it into this pass. (Surfaced while auditing §5.4 — it is the one
  call site where the heat ramp is genuinely the wrong encoding *because the input is wrong*.)
