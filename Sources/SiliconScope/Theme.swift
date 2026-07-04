//
//  File:      Theme.swift
//  Created:   2026-06-08
//  Updated:   2026-07-04
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Shared visual language and reusable UI atoms (Card, Bar, KV, Sparkline,
//             PopoverButtonStyle).
//             Restrained instrument-panel look: one accent, muted heat colors, dense
//             monospaced typography. All in-app text is English.
//  Notes:     Theme.heat(fraction) maps 0...1 load to green/amber/red. Cards are
//             neutral (no per-card colors) so data — not chrome — carries the eye.
//             Bottleneck.color lives here (UI layer) so SiliconScopeCore stays SwiftUI-free.
//
import SwiftUI
import Charts
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
        case .jan, .gpt4all, .vllm: return "brain"
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
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
                .padding(.top, 14)   // breathing room between the last Bar and the chart (~one Bar tall)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        // In a warning state the card border is tinted (amber = elevated, red = critical) so the
        // user can see AT A GLANCE which metric is under pressure — not just a global banner (#18).
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(alert ?? Theme.border, lineWidth: alert == nil ? 1 : 1.5))
        // Clip last so the chart's area gradient respects the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: 9))
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
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
            HStack(spacing: 0) {
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
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
        }
    }
}

struct KV: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack {
            Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(valueColor)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var height: CGFloat = 26
    /// Fixed Y range. When nil, Swift Charts auto-scales to the data (good for series that
    /// vary). Set it (e.g. 0...1) for near-constant series like memory usage, where
    /// auto-scaling amplifies a flat line to fill the whole height.
    var yDomain: ClosedRange<Double>? = nil
    /// Expand to fill the available space instead of a fixed height — so a card with few Bars
    /// (e.g. CPU) uses its full lower area rather than leaving a gap above a short chart (#24).
    var fill: Bool = false
    /// Dotted horizontal gridlines behind the trace, for easier reading of the level (#24).
    var grid: Bool = false

    var body: some View {
        let chart = Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), .clear],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            if grid {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.40))
                }
            }
        }
        .chartLegend(.hidden)
        .modifier(SparkSize(fill: fill, height: height))

        if let yDomain {
            chart.chartYScale(domain: yDomain)
        } else {
            chart
        }
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(fill(pressed: pressed), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
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
