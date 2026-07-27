//
//  File:      Theme.swift
//  Created:   2026-06-08
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Shared visual language and reusable UI atoms (Card, Bar, KV, Sparkline,
//             PopoverButtonStyle), plus the Layout dimension tokens.
//             Restrained instrument-panel look: one accent, muted heat colors, dense
//             monospaced typography. All in-app text is English.
//  Notes:     Theme.heat(fraction) maps 0...1 load to green/amber/red. Cards are
//             neutral (no per-card colors) so data — not chrome — carries the eye.
//             Bottleneck.color lives here (UI layer) so SiliconScopeCore stays SwiftUI-free.
//             Layout holds every fixed dimension, named by role; see docs/design-system.md.
//             Layout.Row's fixed-vs-minHeight comments are load-bearing (#23/#25/#16), and
//             Layout.hairline must never be scaled.
//
import SwiftUI
import SiliconScopeCore

enum Theme {
    static let bg     = Color(red: 0.051, green: 0.055, blue: 0.067)
    static let panel  = Color(red: 0.086, green: 0.094, blue: 0.110)
    static let border = Color.white.opacity(0.065)
    static let text   = Color(red: 0.90, green: 0.91, blue: 0.93)
    static let dim    = Color(red: 0.48, green: 0.51, blue: 0.57)
    static let faint  = Color(red: 0.34, green: 0.37, blue: 0.42)
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.98)

    static func heat(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.55: return Color(red: 0.34, green: 0.74, blue: 0.49)
        case ..<0.82: return Color(red: 0.87, green: 0.66, blue: 0.28)
        default:      return Color(red: 0.88, green: 0.37, blue: 0.37)
        }
    }
}

// MARK: - UI scale

/// App zoom and layout density — the only scale axis SiliconScope exposes.
///
/// **Why not Dynamic Type** (decision D1, docs/design-system.md §3.5): macOS "Larger Text" is an
/// unbounded input, and this layout is already at its margin — the dense Memory column can exceed
/// its fixed row height under some macOS text metrics (#25, a re-run of #23). A user who enlarged
/// system text would re-trigger that overflow having never touched a SiliconScope setting. Owning
/// the range keeps it clamped and testable.
///
/// **Why the store rather than an EnvironmentKey**: an environment value injected at the window
/// root reaches exactly one of the app's eleven SwiftUI surfaces. The eight menu-bar dropdowns are
/// each a separate `NSHostingController` root (`MetricBarController.makeEntry`) and Settings is a
/// sibling `Scene`, so neither inherits it — and those hosting controllers are created once and
/// never re-made, so anything captured at construction would be stale forever. Every root reads
/// `@AppStorage(UIScale.zoomKey)` itself to invalidate, and the tokens read the store.
enum UIScale {
    static let zoomKey = "ui.zoom"
    static let densityKey = "ui.density"

    /// Allowed zoom steps.
    ///
    /// Floor is 0.9, not 0.85: `.caption` (9 pt) × 0.85 = 7.65 pt monospaced, and the 7 pt
    /// disclosure chevron would fall to 5.95 pt. Ceiling is **provisional** — the real limit is
    /// whatever `Layout.Row.dense` is measured to survive (docs/design-system.md §7 Q1).
    static let steps: [CGFloat] = [0.9, 1.0, 1.15, 1.3]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [zoomKey: 1.0, densityKey: Density.standard.rawValue])
    }

    /// Current zoom. Read from the store on every access rather than cached: `UserDefaults.standard`
    /// is an in-memory dictionary after first use, so this is ~100 ns, and reading live means there
    /// is no observer to keep in sync and no window where a token returns a stale scale.
    static var current: CGFloat {
        let v = CGFloat(UserDefaults.standard.double(forKey: zoomKey))
        guard v > 0 else { return 1 }
        return min(max(v, steps.first ?? 0.9), steps.last ?? 1.3)
    }

    static var density: Density {
        Density(rawValue: UserDefaults.standard.string(forKey: densityKey) ?? "") ?? .standard
    }

    /// Menu-bar glyph scale, capped independently of `current`. macOS fixes the menu-bar height,
    /// so a glyph can only grow WIDER — and Part B (#27) will put more items in the bar, where
    /// width is the scarce resource on a notched Mac.
    static var glyph: CGFloat { min(current, 1.15) }

    /// Moves zoom one step up (+1) or down (-1). Returns the new value.
    @discardableResult
    static func step(_ direction: Int) -> CGFloat {
        let now = current
        let i = steps.firstIndex(where: { abs($0 - now) < 0.001 }) ?? steps.firstIndex(of: 1.0) ?? 1
        let next = steps[min(max(i + direction, 0), steps.count - 1)]
        UserDefaults.standard.set(Double(next), forKey: zoomKey)
        return next
    }

    static func reset() { UserDefaults.standard.set(1.0, forKey: zoomKey) }

    /// Scales a dimension, rounded to a half point so hairlines and 1 pt borders stay crisp.
    static func scaled(_ value: CGFloat) -> CGFloat { (value * current * 2).rounded() / 2 }
}

/// Layout density. Affects SPACING only, never type — "smaller text" (zoom) and "tighter layout"
/// (density) are different wishes, and conflating them into one slider is why a single control
/// feels wrong. Matches iStat Menus' standard/compact menu-bar spacing split.
enum Density: String, CaseIterable {
    case standard, compact
    var factor: CGFloat { self == .compact ? 0.75 : 1 }
    var label: String { self == .compact ? "Compact" : "Standard" }
}

// MARK: - Type tokens

extension Theme {

    /// Semantic type roles. Size, weight and tracking are properties of the ROLE — never of the
    /// call site. Phase 1 of the design-system pass (docs/design-system.md §3.1).
    ///
    /// Roles are assigned by MEANING, not by current size. Of the 15 sites at 9.5 pt today only
    /// one is a card title; the rest are footnotes and SF Symbols. Migrating "everything 9.5 pt →
    /// .sectionMajor" would put semibold + 1.5 tracking on an IP address. Phase 2 assigns each
    /// site by what it *is*.
    ///
    /// ⚠️ SF Symbol point sizes are NOT typography — use `Icon.*` for those.
    enum Role {
        /// Card titles — the dashboard's top-level section label.
        case sectionMajor
        /// Sub-headers *inside* a card (MEMORY / BANDWIDTH) and table headers. Must stay visually
        /// distinct from `.sectionMajor`: the two are vertically adjacent in the same card
        /// (MemoryBandwidthCard, NetworkDiskCard), so collapsing them flattens a working
        /// two-level hierarchy.
        case sectionMinor
        /// Dropdown section headers — accent-coloured and centered (`MenuSectionHeader`).
        case sectionMenu
        /// Footnotes, axis labels, explanatory text.
        case caption
        /// Secondary value on a row.
        case detail
        /// Default row label and value.
        case body
        /// Buttons and promoted values.
        case emphasis
        /// The single headline number on a card.
        case headline
    }

    /// Weight axis, orthogonal to `Role`. Real usage is ~13 sizes × 4 weights and weight is NOT a
    /// function of size — `MenuKV` distinguishes label from value by weight alone at the same
    /// 11 pt. A single-axis scale that baked one weight per size would erase that everywhere.
    ///
    /// Section roles carry their own fixed weight and ignore this axis.
    enum Emphasis { case plain, strong }

    /// The font for a role.
    ///
    /// Deliberately a pure function returning `Font`, not a custom `ViewModifier`: the dashboard's
    /// dominant energy cost is re-evaluating its body every tick (docs/energy-optimization.md §1),
    /// and a `.ssFont()` modifier would add a `ModifiedContent` node plus an environment edge at
    /// each of ~150 call sites. `.font(...)` is primitive and costs nothing extra.
    ///
    /// Phase 3 makes `size(_:)` a function of `ui.zoom`; because call sites name a role rather
    /// than a number, that change lands in this file alone.
    static func font(_ role: Role, _ emphasis: Emphasis = .plain) -> Font {
        .system(size: size(role), weight: weight(role, emphasis), design: .monospaced)
    }

    /// Letter spacing for a role, 0 where it has none. Applied at the call site with SwiftUI's
    /// primitive `.tracking()`, for the same reason `font(_:_:)` is not a ViewModifier.
    static func tracking(_ role: Role) -> CGFloat {
        switch role {
        case .sectionMajor: return 1.5
        case .sectionMinor: return 1.2
        case .sectionMenu:  return 1.0
        default:            return 0
        }
    }

    /// Scaled point size for a role.
    ///
    /// Clamped to a per-role floor rather than scaling freely: at the 0.9 step a role already at
    /// 9 pt lands on 8.1 pt monospaced, which is past legibility on a dense panel. The clamp binds
    /// only at the smallest step, so it never fights zooming *up*.
    private static func size(_ role: Role) -> CGFloat {
        let base = baseSize(role)
        return max((base * UIScale.current * 2).rounded() / 2, floorSize(role))
    }

    private static func baseSize(_ role: Role) -> CGFloat {
        switch role {
        case .sectionMajor: return 9.5
        case .sectionMinor: return 9
        case .sectionMenu:  return 10
        case .caption:      return 9
        case .detail:       return 10.5
        case .body:         return 11
        case .emphasis:     return 12
        case .headline:     return 14
        }
    }

    /// Smallest point size a role may render at, whatever the zoom.
    private static func floorSize(_ role: Role) -> CGFloat {
        switch role {
        case .sectionMajor, .sectionMinor, .sectionMenu, .caption: return 8.5
        case .detail, .body:                                       return 9.5
        case .emphasis, .headline:                                 return 11
        }
    }

    private static func weight(_ role: Role, _ emphasis: Emphasis) -> Font.Weight {
        switch role {
        // Section roles are always heavy; the emphasis axis does not apply.
        case .sectionMajor, .sectionMinor: return .semibold
        case .sectionMenu:                 return .bold
        case .caption:   return emphasis == .strong ? .semibold : .regular
        case .detail:    return emphasis == .strong ? .medium   : .regular
        case .body:      return emphasis == .strong ? .medium   : .regular
        // `.emphasis` is a SIZE step whose modal weight is already medium (12 pt: 6 medium,
        // 3 semibold, 2 regular), so `.plain` is medium here rather than regular.
        case .emphasis:  return emphasis == .strong ? .semibold : .medium
        // Every current headline-sized site is bold; `.strong` preserves them exactly in phase 2.
        case .headline:  return emphasis == .strong ? .bold     : .semibold
        }
    }
}

// MARK: - Space, radius and icon tokens

/// Stack spacing and padding, tuned to the MODAL value of each cluster so the common case does
/// not move. (An earlier draft used round numbers and picked `card = 9`, a value that occurs zero
/// times in the codebase — `spacing: 8` occurs 16 times.)
///
/// Applied in phase 2, which is a declared normalisation rather than a no-op: collapsing the 16
/// padding and 14 spacing literals onto these seven tokens moves some sites by 1–4 pt. Values with
/// documented intent are pinned instead of collapsed (see `cardGraphGap`).
///
/// Phase 3: every token below is scaled by `ui.zoom` AND by `ui.density`. Density touches spacing
/// only — see `Density`.
enum Space {
    /// Required exactly-zero — `StackedBar` and `MenuStackedBar` depend on segments touching.
    /// Never scaled: zero times anything is still zero, but stating it keeps the intent explicit.
    static let none: CGFloat = 0
    static var hair: CGFloat    { s(2) }   // ×16
    static var tight: CGFloat   { s(4) }   // ×12
    static var row: CGFloat     { s(6) }   // ×35 — dominant
    static var card: CGFloat    { s(8) }   // ×16
    static var section: CGFloat { s(12) }  // ×7
    static var page: CGFloat    { s(20) }  // ×3
    /// Gap between a `Card`'s last row and its fill-graph. Pinned, not collapsed into `section`:
    /// the value is documented as "~one Bar tall" (#24), so it tracks the Bar atom's height
    /// rather than the spacing scale.
    static var cardGraphGap: CGFloat { s(14) }

    private static func s(_ v: CGFloat) -> CGFloat {
        (v * UIScale.current * UIScale.density.factor * 2).rounded() / 2
    }
}

/// Corner radii. Three surface sizes, not seven arbitrary values.
enum Radius {
    /// Buttons, text fields and other controls (`PopoverButtonStyle`).
    static var control: CGFloat { UIScale.scaled(7) }
    /// Inset panels and badges *inside* a card — the warning banner, Inspector badges, Linux
    /// metric blocks, Fleet tiles. The modal radius in the codebase (5 sites at 8).
    static var panel: CGFloat { UIScale.scaled(8) }
    /// Cards — the dashboard's top-level surface.
    static var card: CGFloat { UIScale.scaled(9) }
    /// Legend swatches. Deliberately NOT `height / 2` — these are 8×8 and 9×9 squares with a
    /// softened corner; a pill rule would render them as circles and change the legend's look.
    static var swatch: CGFloat { UIScale.scaled(2) }
    /// Capsules — meters and tracks, where fully rounded is the intent. Takes an ALREADY-SCALED
    /// height, so it must not scale again.
    static func pill(_ height: CGFloat) -> CGFloat { height / 2 }
}

/// Menu-bar glyph metrics — the AppKit rasterisers in `MenuBarGlyph` / `MenuBarIcon`.
///
/// A third type system, unavoidably: glyphs are drawn to `NSImage` with `NSFont`, not laid out by
/// SwiftUI, so they can use neither `Theme.Role` nor `Icon`. They are also bounded differently —
/// macOS fixes the menu-bar height, so a glyph can only ever grow WIDER (docs/design-system.md
/// §3.6), which is why glyph scale is capped separately from `ui.zoom`.
enum Glyph {
    /// Usable menu-bar height. Fixed by macOS — not a design choice, and **never scaled**.
    /// This is why glyph zoom only widens a glyph, and why `UIScale.glyph` is capped.
    static let height: CGFloat = 18
    /// The vertical per-character label ("C/P/U") that precedes every metric glyph.
    static var stackedLabel: CGFloat { g(6.5) }
    /// The combined "SS" glyph's label, one step larger than a per-metric one.
    static var comboLabel: CGFloat { g(7.5) }
    /// Two-line value rows (MEM / NET / SSD / SEN).
    static var value: CGFloat { g(8.5) }
    /// A single value row (`GlyphMode.value`). Larger than `value` because one row owns the whole
    /// 18 pt height — sizing a one-row glyph like a two-row one wastes half the menu bar.
    static var singleValue: CGFloat { g(11) }
    /// Battery percentage beside the battery body.
    static var batteryValue: CGFloat { g(9) }

    /// Glyph text scales on the capped glyph axis, and never past what the fixed 18 pt height can
    /// hold — two stacked value rows must still fit.
    private static func g(_ v: CGFloat) -> CGFloat { (v * UIScale.glyph * 2).rounded() / 2 }
}

/// SF Symbol point sizes. Separate from `Theme.Role` because a symbol is not text: it has no
/// weight/tracking axis and does not belong in the type scale.
enum Icon {
    /// Disclosure chevrons. Floored at 7 pt — below that a chevron reads as a smudge.
    static var micro: CGFloat { max(UIScale.scaled(7), 7) }
    static var small: CGFloat { UIScale.scaled(9) }
    static var medium: CGFloat { UIScale.scaled(10) }
    static var large: CGFloat { UIScale.scaled(11) }
    /// Empty-state / error symbols that carry a whole view (Fleet pairing prompts). The only
    /// icon size that is a focal point rather than an adornment.
    static var hero: CGFloat { UIScale.scaled(26) }
}

/// Fixed layout dimensions, named by ROLE rather than by value.
///
/// Phase 0 of the design-system pass (docs/design-system.md §3.4): these are definitions only —
/// no call site uses them yet, so adding this type changes nothing on screen. Phases 2–3 migrate
/// the literals here and turn the values into functions of `ui.zoom`.
///
/// Why this exists at all: type size is NOT what blocks app zoom (#19) — fixed geometry is. The
/// dashboard carries 8 fixed/min heights and 39 fixed widths, and the grid is already at its
/// margin at zoom 1.0 (see `Row.dense` below). Scaling type without scaling these would re-run
/// #23/#25 and truncate every column to "…".
///
/// ⚠️ The fixed-height vs minHeight distinction in `Row` is SEMANTIC, not incidental. Each row
/// documents which it must be and why; collapsing them into "just row heights" is exactly how
/// #23/#25/#16 were introduced.
enum Layout {

    /// Dashboard grid row heights (`DashboardView`).
    enum Row {
        /// AI cockpit pair — **minHeight**. Content-driven, both cards are short.
        static var aiCockpit: CGFloat { UIScale.scaled(108) }
        /// SensorsCard in the narrow/remote variant — **minHeight**.
        static var sensorsNarrow: CGFloat { UIScale.scaled(120) }
        /// CPU + Accelerator — **fixed height**. Both cards carry a fill-graph that absorbs
        /// content changes by shrinking/growing, so the card size stays put (#24).
        static var graphed: CGFloat { UIScale.scaled(166) }
        /// Memory/Bandwidth and Network/Disk — **minHeight, never a fixed height**. These cards
        /// are graphless (trends live inside the sections), and the dense Memory column's
        /// intrinsic height (~188 pt) can exceed a fixed 176 by a few points under some macOS
        /// versions' text metrics, spilling into the neighbouring card (#25, a re-run of #23).
        /// Growing to fit makes the overflow structurally impossible.
        /// **This is the row that bounds the zoom ceiling** (docs/design-system.md §7 Q1).
        static var dense: CGFloat { UIScale.scaled(176) }
        /// Sensors + Processes — **fixed height**. ProcessCard scrolls its list internally, so it
        /// needs a bounded height; minHeight lets the whole list expand and balloons the window.
        static var scrolling: CGFloat { UIScale.scaled(196) }
    }

    /// Window, sheet and popover sizes.
    enum Surface {
        /// Per-metric menu-bar dropdowns (7 call sites, all identical).
        static var dropdownWidth: CGFloat { UIScale.scaled(260) }
        /// Ceiling for a scrolling list inside a dropdown (the sensor list), so a machine with
        /// many sensors cannot grow the popover past the screen.
        static var dropdownScrollMax: CGFloat { UIScale.scaled(320) }
        /// Combined "SS" dropdown — wider when the compact GPU layout is on.
        static var combinedWidth: CGFloat { UIScale.scaled(270) }
        static var combinedWidthCompactGPU: CGFloat { UIScale.scaled(340) }
        static var inspector: CGSize { CGSize(width: UIScale.scaled(460), height: UIScale.scaled(640)) }
        static var settingsWidth: CGFloat { UIScale.scaled(400) }
        static var settingsHeight: CGFloat { UIScale.scaled(710) }
        /// Settings grows when the AI-runtime section is expanded.
        static var settingsHeightExpanded: CGFloat { UIScale.scaled(820) }
        static var addMachineWidth: CGFloat { UIScale.scaled(440) }
        static var fleetDetailWidth: CGFloat { UIScale.scaled(400) }
        static var mainWindowMin: CGSize { CGSize(width: UIScale.scaled(640), height: UIScale.scaled(600)) }
    }

    /// Text-bearing column widths. These are the sites that TRUNCATE to "…" under zoom, so they
    /// must scale — or, better, become intrinsic. The process table is slated to move to `Grid`
    /// + `.gridColumnAlignment` in phase 2, which removes the first three entirely.
    enum Column {
        static var processPID: CGFloat { UIScale.scaled(56) }
        static var processCPU: CGFloat { UIScale.scaled(60) }
        static var processMemory: CGFloat { UIScale.scaled(84) }
        /// Engine/state label in the AI cockpit rows.
        static var stateLabel: CGFloat { UIScale.scaled(42) }
        /// Menu-bar dropdown trend rows: label column + right-aligned value column.
        static var trendLabel: CGFloat { UIScale.scaled(28) }
        static var trendValue: CGFloat { UIScale.scaled(56) }
        /// CPU dropdown frequency readout.
        static var frequency: CGFloat { UIScale.scaled(64) }
        /// Sensors dropdown: temperature value and fan RPM.
        static var sensorValue: CGFloat { UIScale.scaled(44) }
        static var fanValue: CGFloat { UIScale.scaled(70) }
        /// Linux fleet view metric label.
        static var linuxLabel: CGFloat { UIScale.scaled(64) }
        /// Inline meter track beside a sensor / fan reading in the dropdowns.
        static var sensorBar: CGFloat { UIScale.scaled(60) }
        /// Port field in the Add Machine sheet.
        static var portField: CGFloat { UIScale.scaled(90) }
    }

    /// Meter and chart heights.
    enum Meter {
        /// `Bar`'s capsule track — the app's default meter.
        static var bar: CGFloat { UIScale.scaled(5) }
        /// Memory composition strip under the headline figure.
        static var strip: CGFloat { UIScale.scaled(4) }
        /// Battery fill in the dropdown.
        static var battery: CGFloat { UIScale.scaled(7) }
        /// `MenuStackedBar` in dropdowns.
        static var stacked: CGFloat { UIScale.scaled(9) }
        /// Inline sparkline beside a value.
        static var sparkline: CGFloat { UIScale.scaled(26) }
        /// `LabeledSparkline`'s trace — shorter than `sparkline` because it sits under a label.
        static var labeledSparkline: CGFloat { UIScale.scaled(18) }
        /// Fleet dual-series chart.
        static var fleetChart: CGFloat { UIScale.scaled(84) }
    }

    /// Status dots and legend swatches.
    enum Dot {
        static var status: CGFloat { UIScale.scaled(7) }
        static var verdict: CGFloat { UIScale.scaled(8) }
        static var swatch: CGFloat { UIScale.scaled(8) }
        static var menuSwatch: CGFloat { UIScale.scaled(9) }
        static var linux: CGFloat { UIScale.scaled(6) }
    }

    /// Controls.
    enum Control {
        /// `PopoverButtonStyle` — uniform button height across every menu-bar surface.
        static var buttonHeight: CGFloat { UIScale.scaled(28) }
        /// Fleet overview tile minimum.
        static var tileMinHeight: CGFloat { UIScale.scaled(26) }
        /// Disclosure chevron / leading icon slots.
        static var chevronWidth: CGFloat { UIScale.scaled(16) }
        static var iconWidth: CGFloat { UIScale.scaled(15) }
    }

    /// A one-point separator rule.
    /// ⚠️ **Never scales.** A hairline multiplied by `ui.zoom` stops being a hairline and starts
    /// being a border; it stays 1 pt at every zoom level.
    static let hairline: CGFloat = 1
}

extension Bottleneck {
    /// UI accent for each verdict: neutral when fine, amber/green for the workload
    /// profiles, red for the two problem states. Kept out of KtopCore (no SwiftUI there).
    var color: Color {
        switch self {
        case .idle:             return Theme.faint
        case .gpuActive:        return Theme.accent
        case .computeBound:     return Theme.heat(0.4)   // GPU well-utilized — healthy
        case .bandwidthBound:   return Theme.heat(0.7)   // a known limiter, expected
        case .thermalThrottled: return Theme.heat(1)
        case .memoryPressured:  return Theme.heat(1)
        }
    }
}

extension AIRuntimeKind {
    /// SF Symbol shown beside the runtime name in the cockpit.
    var symbol: String {
        switch self {
        case .ollama:   return "shippingbox.fill"
        case .llamaCpp: return "terminal.fill"
        case .lmStudio: return "macwindow"
        case .mlx:      return "cpu.fill"
        case .rapidMLX: return "hare.fill"
        case .exo:      return "point.3.connected.trianglepath.dotted"   // distributed cluster
        case .jan, .gpt4all, .vllm, .omlx: return "brain"
        }
    }
    var color: Color { Theme.accent }
}

extension MemoryBudget.Risk {
    /// UI accent: neutral when OK, amber when tight, red while swapping.
    var color: Color {
        switch self {
        case .ok:       return Theme.dim
        case .tight:    return Theme.heat(0.7)
        case .swapping: return Theme.heat(1)
        }
    }
    var label: String {
        switch self {
        case .ok:       return "OK"
        case .tight:    return "tight"
        case .swapping: return "swapping"
        }
    }
}

/// Formats a Celsius value in the user's chosen unit.
func formatTemperature(_ celsius: Double, fahrenheit: Bool) -> String {
    fahrenheit
        ? String(format: "%.0f°F", celsius * 9.0 / 5.0 + 32.0)
        : String(format: "%.0f°C", celsius)
}

/// Human-readable transfer rate (B/s, KB/s, MB/s, GB/s).
func formatRate(_ bytesPerSec: Double) -> String {
    let v = max(0, bytesPerSec)
    if v >= 1_000_000_000 { return String(format: "%.1f GB/s", v / 1_000_000_000) }
    if v >= 1_000_000     { return String(format: "%.1f MB/s", v / 1_000_000) }
    if v >= 1_000         { return String(format: "%.0f KB/s", v / 1_000) }
    return String(format: "%.0f B/s", v)
}

/// Human-readable byte size (MB, GB, TB).
func formatBytes(_ bytes: UInt64) -> String {
    let v = Double(bytes)
    if v >= 1_000_000_000_000 { return String(format: "%.2f TB", v / 1_000_000_000_000) }
    if v >= 1_000_000_000     { return String(format: "%.0f GB", v / 1_000_000_000) }
    if v >= 1_000_000         { return String(format: "%.0f MB", v / 1_000_000) }
    return "\(bytes) B"
}

struct Card<Content: View, Graph: View>: View {
    let title: String
    var menuBarPin: Binding<Bool>? = nil   // when set, a switch in the title promotes the card to the menu bar
    var alert: Color? = nil                // non-nil → warning state: colored border (memory pressure / GPU throttle)
    @ViewBuilder var content: Content
    /// Optional graph that fills the card's spare space BELOW the content (in-flow, fill: true), so a
    /// card with few Bars uses its full lower area instead of leaving a gap (#24). It sits in a
    /// FIXED-height row, so it absorbs content changes by shrinking/growing rather than resizing the
    /// card. Graphless cards pass EmptyView (collapses; content stays top-aligned).
    @ViewBuilder var graph: Graph

    init(title: String, menuBarPin: Binding<Bool>? = nil, alert: Color? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder graph: () -> Graph) {
        self.title = title
        self.menuBarPin = menuBarPin
        self.alert = alert
        self.content = content()
        self.graph = graph()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(spacing: Space.row) {
                Text(title.uppercased())
                    .font(Theme.font(.sectionMajor))
                    .tracking(Theme.tracking(.sectionMajor))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
                if let pin = menuBarPin { MenuBarPin(isOn: pin) }
            }
            // Rows flow top-down at natural height, then the graph (when present) fills the space
            // BELOW them — so a card with few Bars (e.g. CPU) uses its full lower area instead of
            // leaving a gap above a short bottom-pinned chart (#24). Graphless cards pass EmptyView,
            // which collapses; the row's minHeight + clip keep a tall graph from spilling past the card.
            content
            graph
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, Space.cardGraphGap)   // breathing room between the last Bar and the chart (~one Bar tall)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Radius.card))
        // In a warning state the card border is tinted (amber = elevated, red = critical) so the
        // user can see AT A GLANCE which metric is under pressure — not just a global banner (#18).
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .strokeBorder(alert ?? Theme.border, lineWidth: alert == nil ? 1 : 1.5))
        // Clip last so the chart's area gradient respects the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}

extension Card where Graph == EmptyView {
    /// Graphless card (most cards): keeps existing `Card(title:) { ... }` call sites working.
    init(title: String, menuBarPin: Binding<Bool>? = nil, alert: Color? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, menuBarPin: menuBarPin, alert: alert, content: content, graph: { EmptyView() })
    }
}

/// A thin labelled progress bar (0...1).
struct Bar: View {
    let label: String
    let value: Double
    let detail: String
    /// Optional fixed fill color; defaults to the load-based heat ramp when nil.
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(spacing: Space.row) {
                Text(label)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(detail)
                    .font(Theme.font(.detail))
                    .foregroundStyle(Theme.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color ?? Theme.heat(value))
                        .frame(width: max(2, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 5)
        }
    }
}

/// A composition bar: adjacent colored segments (e.g. memory Wired/Active/Compressed/Free).
struct StackedBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Space.none) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segment.color.frame(width: max(0, geo.size.width * min(1, segment.fraction)))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// Small colored dot + label + value, for stacked-bar legends.
struct LegendRow: View {
    let color: Color
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: Space.row) {
            RoundedRectangle(cornerRadius: Radius.swatch).fill(color).frame(width: Layout.Dot.swatch, height: Layout.Dot.swatch)
            Text(key).font(Theme.font(.body)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(Theme.font(.body)).foregroundStyle(Theme.text)
        }
    }
}

struct KV: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack {
            Text(key).font(Theme.font(.body)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(Theme.font(.body)).foregroundStyle(valueColor)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var height: CGFloat = 26
    /// Fixed Y range. When nil, the trace auto-scales to the data's own min...max (good for series
    /// that vary). Set it (e.g. 0...1) for near-constant series like memory usage, where
    /// auto-scaling would amplify a flat line to fill the whole height.
    var yDomain: ClosedRange<Double>? = nil
    /// Expand to fill the available space instead of a fixed height — so a card with few Bars
    /// (e.g. CPU) uses its full lower area rather than leaving a gap above a short chart (#24).
    var fill: Bool = false
    /// Dotted horizontal gridlines behind the trace, for easier reading of the level (#24).
    var grid: Bool = false

    // Drawn with a Canvas instead of Swift Charts: ~13 live sparklines rebuilt every tick made
    // Charts' mark/scale/plot view-graph the dominant energy cost (docs/energy-optimization.md
    // FIX 1). A Canvas is a single draw closure — same look, far cheaper per redraw.
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard values.count > 1, size.width > 0, size.height > 0 else { return }
            let lo = yDomain?.lowerBound ?? (values.min() ?? 0)
            let hi = yDomain?.upperBound ?? (values.max() ?? 1)
            let span = hi - lo
            let flat = span <= .ulpOfOne          // degenerate/flat series → center (not floor)
            let stepX = size.width / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                let norm = flat ? 0.5 : (values[i] - lo) / span
                return CGPoint(x: CGFloat(i) * stepX, y: (1 - CGFloat(norm)) * size.height)
            }
            // Dotted horizontal gridlines behind the trace (#24): 3 evenly-spaced interior lines.
            if grid {
                var g = Path()
                for k in 1...3 {
                    let y = size.height * CGFloat(k) / 4
                    g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(g, with: .color(Theme.dim.opacity(0.40)),
                           style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
            }
            // Line trace.
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            // Area = the line closed down to the baseline, filled with a top→bottom gradient.
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .modifier(SparkSize(fill: fill, height: height))
        // Decorative trace: hide from accessibility (the numeric value is shown as text on the
        // card). Skips the per-tick SwiftUI accessibility-node recompute on every live sparkline.
        .accessibilityHidden(true)
    }
}

/// Sizes a Sparkline: fill the available space (bottom-anchored charts that grow into the card's
/// spare area) or a fixed height (inline sparklines in a column).
private struct SparkSize: ViewModifier {
    let fill: Bool
    let height: CGFloat
    func body(content: Content) -> some View {
        if fill { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else    { content.frame(height: height) }
    }
}

/// Popover footer button styled to match the cards: rounded panel fill, hairline border,
/// monospaced label, uniform 28pt height, with hover + press feedback. `prominent` adds a
/// subtle accent tint + outline for the single primary action (Open Dashboard); the others
/// stay neutral so the hierarchy reads at a glance. Shared by the combined popover and each
/// per-metric dropdown so every menu-bar surface uses the same buttons.
struct PopoverButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, prominent: prominent)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(Theme.font(.emphasis))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(fill(pressed: pressed), in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(stroke, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: pressed)
        }

        private func fill(pressed: Bool) -> Color {
            if prominent {
                return Theme.accent.opacity(pressed ? 0.34 : hovering ? 0.26 : 0.18)
            }
            return Color.white.opacity(pressed ? 0.14 : hovering ? 0.10 : 0.05)
        }

        private var stroke: Color {
            prominent ? Theme.accent.opacity(0.55) : Theme.border
        }
    }
}
