//
//  File:      MenuBarMetric.swift
//  Created:   2026-06-19
//  Updated:   2026-06-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  iStat-style per-metric menu-bar items. Each dashboard card can be toggled
//             into its own menu-bar item (a stacked label + a mini histogram or two-line
//             value readout), with its own dropdown. Glyphs are drawn to NSImage (the only
//             reliable way to render a live MenuBarExtra label) and adapt to the menu-bar
//             appearance; value bars keep their metric color.
//  Notes:     Per-metric on/off persists in UserDefaults ("menubar.cpu" etc.); the App
//             conditionally inserts a MenuBarExtra per enabled metric. The combined SS
//             glyph (MenuBarIcon) stays on by default.
//
import SwiftUI
import AppKit
import SiliconScopeCore

// MARK: - Glyph rendering (NSImage)

enum MenuBarGlyph {
    private static let height: CGFloat = 18

    /// Stacked label like iStat ("CPU" → C/P/U). Returns the column width it occupied.
    @discardableResult
    private static func drawStackedLabel(_ text: String, ink: NSColor) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 6.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(0.85)]
        let chars = text.map { String($0) as NSString }
        let colW = ceil(chars.map { $0.size(withAttributes: attrs).width }.max() ?? 6)
        let slot = height / CGFloat(chars.count)
        for (i, ch) in chars.enumerated() {
            let sz = ch.size(withAttributes: attrs)
            let y = height - CGFloat(i + 1) * slot + (slot - sz.height) / 2
            ch.draw(at: NSPoint(x: (colW - sz.width) / 2, y: y), withAttributes: attrs)
        }
        return colW
    }

    /// Stacked label + a mini history histogram (CPU / GPU). `values` are 0...1.
    static func histogram(label: String, values: [Double], color: NSColor, dark: Bool) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let barCount = 11
        let barW: CGFloat = 2.0, barGap: CGFloat = 1.0, gap: CGFloat = 2.5
        let barsW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap
        // measure label column once (re-measured in the draw block; cheap)
        let labelW: CGFloat = 7
        let width = ceil(labelW + gap + barsW) + 1
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let w = drawStackedLabel(label, ink: ink)
            let originX = w + gap
            let track = ink.withAlphaComponent(0.14)
            let vals = Array(values.suffix(barCount))
            for i in 0..<barCount {
                let x = originX + CGFloat(i) * (barW + barGap)
                track.setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: barW, height: height)).fill()
                let idx = i - (barCount - vals.count)
                if idx >= 0, idx < vals.count {
                    let v = max(0, min(1, vals[idx]))
                    color.setFill()
                    NSBezierPath(rect: NSRect(x: x, y: 0, width: barW, height: max(1.5, height * CGFloat(v)))).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Stacked label + thick value bars (SS-glyph thickness), one color per bar with a
    /// full-height track. Used for CPU (E left, P right) and other few-value metrics.
    static func bars(label: String, values: [Double], colors: [NSColor], dark: Bool) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let barW: CGFloat = 6.5, gap: CGFloat = 2.0, radius: CGFloat = 1.2
        let n = CGFloat(values.count)
        let barsW = barW * n + gap * (n - 1)
        let labelW: CGFloat = 8, lgap: CGFloat = 3
        let width = ceil(labelW + lgap + barsW) + 1
        let track = ink.withAlphaComponent(0.16)
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let w = drawStackedLabel(label, ink: ink)
            let originX = w + lgap
            for (i, v) in values.enumerated() {
                let x = originX + CGFloat(i) * (barW + gap)
                track.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: height),
                             xRadius: radius, yRadius: radius).fill()
                let h = max(2.5, height * CGFloat(min(1, max(0, v))))
                colors[min(i, colors.count - 1)].setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h),
                             xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Stacked label + two "prefix … value" rows (MEM / NET / SSD), iStat style: the prefix
    /// ("U:" / "F:" / "↓") is pinned left and the value is right-aligned in a fixed column, so
    /// numbers line up cleanly and the glyph width never changes as values grow/shrink.
    /// `reserveValue` is a worst-case value template ("999.9 GB") that sets the value column.
    static func twoLine(label: String, prefix1: String, value1: String,
                        prefix2: String, value2: String, dark: Bool, reserveValue: String) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let pAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(0.72)]
        let vAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(0.95)]
        let p1 = prefix1 as NSString, p2 = prefix2 as NSString
        let v1 = value1 as NSString, v2 = value2 as NSString
        let prefixW = ceil(max(p1.size(withAttributes: pAttrs).width, p2.size(withAttributes: pAttrs).width))
        let valueW = ceil(max((reserveValue as NSString).size(withAttributes: vAttrs).width,
                              v1.size(withAttributes: vAttrs).width, v2.size(withAttributes: vAttrs).width))
        let gap: CGFloat = 3, innerGap: CGFloat = 4, labelW: CGFloat = 7
        let width = ceil(labelW + gap + prefixW + innerGap + valueW) + 2
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let w = drawStackedLabel(label, ink: ink)
            let originX = w + gap
            let valueRight = originX + prefixW + innerGap + valueW
            let lh = v1.size(withAttributes: vAttrs).height
            let yTop = height / 2 + (height / 2 - lh) / 2
            let yBot = (height / 2 - lh) / 2
            p1.draw(at: NSPoint(x: originX, y: yTop), withAttributes: pAttrs)                                   // prefix left
            p2.draw(at: NSPoint(x: originX, y: yBot), withAttributes: pAttrs)
            v1.draw(at: NSPoint(x: valueRight - v1.size(withAttributes: vAttrs).width, y: yTop), withAttributes: vAttrs)  // value right
            v2.draw(at: NSPoint(x: valueRight - v2.size(withAttributes: vAttrs).width, y: yBot), withAttributes: vAttrs)
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Battery icon (outline + proportional fill + terminal nub) followed by "NN%", with an
    /// iStat-style state badge to the left: a bolt while charging, a plug while plugged in
    /// (AC) but not charging, nothing on battery. Fill turns red at/under 20% on battery.
    static func battery(percent: Double, charging: Bool, plugged: Bool, dark: Bool) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let pct = max(0, min(100, percent))
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(0.95)]
        let label = String(format: "%.0f%%", pct) as NSString
        let textW = ceil(label.size(withAttributes: attrs).width)

        // State badge (drawn to the left of the body).
        let charge = NSColor(srgbRed: 0.36, green: 0.82, blue: 0.45, alpha: 1)
        let badge: NSImage? = charging ? tintedSymbol("bolt.fill", color: charge, pointSize: 9)
            : (plugged ? tintedSymbol("powerplug.fill", color: ink.withAlphaComponent(0.8), pointSize: 8) : nil)
        let badgeW: CGFloat = badge.map { ceil($0.size.width) + 3 } ?? 0

        // Upright battery: narrow body with the terminal nub on top, fill rising from bottom.
        let bodyW: CGFloat = 9, bodyH: CGFloat = 13, nubW: CGFloat = 4, nubH: CGFloat = 1.6, gap: CGFloat = 4
        let width = ceil(badgeW + bodyW + gap + textW) + 2
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let badge {
                badge.draw(at: NSPoint(x: 0, y: (height - badge.size.height) / 2),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            let bottom = (height - bodyH - nubH) / 2
            let body = NSRect(x: badgeW + 0.5, y: bottom, width: bodyW, height: bodyH)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            ink.withAlphaComponent(0.55).setStroke(); outline.stroke()
            // terminal nub (centered on top)
            ink.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.midX - nubW / 2, y: body.maxY - 0.3, width: nubW, height: nubH),
                         xRadius: 0.8, yRadius: 0.8).fill()
            // fill rising from the bottom
            let inner = body.insetBy(dx: 1.8, dy: 1.8)
            let low = !plugged && pct <= 20
            let fillColor: NSColor = charging ? charge
                : (low ? NSColor(srgbRed: 0.92, green: 0.36, blue: 0.34, alpha: 1) : ink.withAlphaComponent(0.85))
            fillColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                             width: inner.width, height: max(1, inner.height * CGFloat(pct / 100))),
                         xRadius: 0.8, yRadius: 0.8).fill()
            label.draw(at: NSPoint(x: body.maxX + gap, y: (height - label.size(withAttributes: attrs).height) / 2),
                       withAttributes: attrs)
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Renders an SF Symbol into a solidly-tinted bitmap (template symbols only carry alpha).
    private static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Shared palette + helpers

enum MetricPalette {
    static let eCPU  = NSColor(srgbRed: 0.95, green: 0.70, blue: 0.30, alpha: 1)  // E-cores amber
    static let pCPU  = NSColor(srgbRed: 0.36, green: 0.62, blue: 0.98, alpha: 1)  // P-cores blue
    static let gpu   = NSColor(srgbRed: 0.40, green: 0.82, blue: 0.55, alpha: 1)  // green
    static let media = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.30, alpha: 1)  // orange
    static let ane   = NSColor(srgbRed: 0.74, green: 0.53, blue: 0.99, alpha: 1)  // purple
    static let down  = NSColor(srgbRed: 0.34, green: 0.74, blue: 0.62, alpha: 1)  // teal
    static let up    = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.30, alpha: 1)  // orange
    // SwiftUI mirrors for dropdown views.
    static var gpuC: Color { Color(nsColor: gpu) }
    static var mediaC: Color { Color(nsColor: media) }
    static var aneC: Color { Color(nsColor: ane) }
    static var downC: Color { Color(nsColor: down) }
    static var upC: Color { Color(nsColor: up) }
}

// Compact one-token formatters for the tiny two-line glyphs ("44G", "3.4T", "202K").
func compactGB(_ gb: Double) -> String { gb >= 1024 ? String(format: "%.1fT", gb / 1024) : String(format: "%.0fG", gb) }
func compactBytes(_ b: UInt64) -> String { compactGB(Double(b) / 1_073_741_824) }
func compactRate(_ bytesPerSec: Double) -> String {
    let k = bytesPerSec / 1024
    return k >= 1024 ? String(format: "%.1fM", k / 1024) : String(format: "%.0fK", k)
}

// iStat-style readouts for the menu-bar glyphs: full unit + space. Disk/network use the
// decimal (1000-base) convention so values match Finder/iStat ("576.2 GB", not 536 GiB).
func iStatBytes(_ b: UInt64) -> String {
    let d = Double(b)
    if d >= 1e12 { return String(format: "%.2f TB", d / 1e12) }
    if d >= 1e9  { return String(format: "%.1f GB", d / 1e9) }
    if d >= 1e6  { return String(format: "%.0f MB", d / 1e6) }
    return String(format: "%.0f KB", d / 1e3)
}
func iStatGB(_ gb: Double) -> String { String(format: "%.1f GB", gb) }   // memory: binary GiB shown as GB
func iStatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1e6 { return String(format: "%.1f MB", bytesPerSec / 1e6) }
    if bytesPerSec >= 1e3 { return String(format: "%.0f KB", bytesPerSec / 1e3) }
    return String(format: "%.0f B", bytesPerSec)
}
/// Tiny temperature readout for the menu-bar glyph ("75°"), honoring the °F setting.
func tempGlyphValue(_ celsius: Double, _ fahrenheit: Bool) -> String {
    guard celsius > 0 else { return "–" }
    return String(format: "%.0f°", fahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius)
}

/// VM page rate for the PAGES panel ("0/s", "1.2K/s").
func pagesRate(_ pagesPerSec: Double) -> String {
    pagesPerSec >= 1000 ? String(format: "%.1fK/s", pagesPerSec / 1000) : String(format: "%.0f/s", pagesPerSec)
}

// MARK: - Shared dropdown components

/// Small faint caption above a history sparkline so it's not a mystery line.
struct GraphCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Theme.faint)
    }
}

struct MenuKV: View {
    let label: String, value: String
    var color: Color = Theme.text
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(color)
        }
    }
}

/// Horizontal stacked segments (fractions summing ~1), iStat memory-bar style.
struct MenuStackedBar: View {
    let segments: [(Double, Color)]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle().fill(seg.1).frame(width: max(0, geo.size.width * seg.0))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Colored swatch + label + value (memory legend).
struct MenuLegendRow: View {
    let color: Color, label: String, value: String
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
        }
    }
}

func memSize(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb >= 1 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

/// Label + value + a fixed-color fill bar (0...1).
struct MenuMeterRow: View {
    let label: String, value: String
    let fraction: Double, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                }
            }.frame(height: 5)
        }
    }
}

/// Brings the main dashboard window forward from AppKit (the per-metric popovers are hosted
/// outside the SwiftUI scene, so @Environment(\.openWindow) isn't available there).
@MainActor func openMainDashboard() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let w = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "siliconscope-main" }) {
        w.makeKeyAndOrderFront(nil)
    } else {
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}

/// Centered accent section header, iStat-style.
struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
            .foregroundStyle(Theme.accent).frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - CPU dropdown

struct CPUMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false

    var body: some View {
        let s = monitor.snapshot
        let e = Color(nsColor: MetricPalette.eCPU)
        let p = Color(nsColor: MetricPalette.pCPU)
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionHeader("CPU")
            coreRow("E-cores", s.cpu.eUsage, s.cpu.eUsagePercent, s.cpu.eFreqMHz, e)
            coreRow("P-cores", s.cpu.pUsage, s.cpu.pUsagePercent, s.cpu.pFreqMHz, p)
            GraphCaption("E (amber) / P (blue) usage · 60s")
            ZStack {   // E (amber) + P (blue) usage history, overlaid
                Sparkline(values: monitor.history.eCPU, color: e, height: 32, yDomain: 0...1)
                Sparkline(values: monitor.history.pCPU, color: p, height: 32, yDomain: 0...1)
            }
            kv("Temperature", formatTemperature(s.temperature.cpuCelsius, fahrenheit: fahrenheit))
            kv("Load avg", SystemInfo.loadAverageString())
            kv("Uptime", SystemInfo.uptimeString())
            Divider()
            MenuSectionHeader("Top Processes")
            ForEach(Array(s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))) { proc in
                HStack(spacing: 6) {
                    Text(proc.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", proc.cpuPercent))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.heat(min(1, proc.cpuPercent / 100)))
                }
            }
            Divider()
            Button { openMainDashboard() } label: {
                Label("Open Dashboard", systemImage: "macwindow").frame(maxWidth: .infinity)
            }
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }

    private func coreRow(_ label: String, _ v: Double, _ pct: Double, _ mhz: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", pct)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                Text(String(format: "%.0f MHz", mhz)).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.faint).frame(width: 64, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, v))))
                }
            }.frame(height: 5)
        }
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Card-title toggle (promote a card to its own menu-bar item)

/// Small, unobtrusive toggle in a card title — promotes the card to its own menu-bar item.
/// A compact icon button (a full switch overpowers the card header).
struct MenuBarPin: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "menubar.rectangle" : "rectangle.dashed")
                .font(.system(size: 10.5))
                .foregroundStyle(isOn ? Theme.accent : Theme.faint)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing in the menu bar — click to hide" : "Show this in the menu bar")
    }
}

struct OpenDashboardButton: View {
    var body: some View {
        Button { openMainDashboard() } label: {
            Label("Open Dashboard", systemImage: "macwindow").frame(maxWidth: .infinity)
        }
    }
}

// MARK: - GPU / MEM / NET / SSD dropdowns

struct GPUMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionHeader("GPU / Media / Neural")
            MenuMeterRow(label: "GPU",
                         value: String(format: "%.0f%%  %.1f W  %.0f MHz", s.gpu.usagePercent, s.power.gpuWatts, s.gpu.freqMHz),
                         fraction: s.gpu.usage, color: MetricPalette.gpuC)
            MenuMeterRow(label: "Media",
                         value: String(format: "%.1f GB/s", s.bandwidth.mediaGBs),
                         fraction: min(1, s.bandwidth.mediaGBs / max(monitor.mediaPeakGBs, 0.5)), color: MetricPalette.mediaC)
            MenuMeterRow(label: "ANE est.",
                         value: String(format: "%.1f W", s.power.aneWatts),
                         fraction: min(1, s.power.aneWatts / max(monitor.anePeakWatts, 0.1)), color: MetricPalette.aneC)
            MenuKV(label: "DRAM power", value: String(format: "%.1f W", s.power.dramWatts))
            GraphCaption("GPU (green) / Media (orange) / ANE (purple) · 60s")
            ZStack {   // all three normalized to 0...1 (each vs its tracked peak)
                Sparkline(values: monitor.history.gpu, color: MetricPalette.gpuC, height: 30, yDomain: 0...1)
                Sparkline(values: monitor.history.media.map { min(1, $0 / max(monitor.mediaPeakGBs, 0.5)) },
                          color: MetricPalette.mediaC, height: 30, yDomain: 0...1)
                Sparkline(values: monitor.history.ane.map { min(1, $0 / max(monitor.anePeakWatts, 0.1)) },
                          color: MetricPalette.aneC, height: 30, yDomain: 0...1)
            }
            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }
}

struct MEMMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    private let wired = Color(red: 0.36, green: 0.62, blue: 0.98)       // blue
    private let active = Color(red: 0.92, green: 0.38, blue: 0.34)      // red (iStat-style)
    private let compressed = Color(red: 0.62, green: 0.55, blue: 0.95)  // purple
    private let freeC = Color.white.opacity(0.12)

    var body: some View {
        let m = monitor.snapshot.memory
        let pressureColor: Color = switch m.pressure {
            case .normal:   Color(red: 0.34, green: 0.74, blue: 0.49)   // green
            case .warning:  Color(red: 0.87, green: 0.66, blue: 0.28)   // amber
            case .critical: Color(red: 0.88, green: 0.37, blue: 0.37)   // red
        }
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader("Memory")
            HStack {
                Text(String(format: "%.1f / %.0f GB", m.usedGB, m.totalGB))
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                Spacer()
                Text(String(format: "%.0f%%", m.usedPercent))
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(monitor.memoryRisk.color)
            }
            MenuStackedBar(segments: [(m.wiredFraction, wired), (m.activeFraction, active),
                                      (m.compressedFraction, compressed), (m.freeFraction, freeC)])
            MenuLegendRow(color: wired, label: "Wired", value: memSize(m.wiredBytes))
            MenuLegendRow(color: active, label: "Active", value: memSize(m.activeBytes))
            MenuLegendRow(color: compressed, label: "Compressed", value: memSize(m.compressedBytes))
            MenuLegendRow(color: freeC, label: "Free", value: memSize(m.freeBytes))

            Divider()
            MenuSectionHeader("Pressure")
            MenuStackedBar(segments: [(m.pressurePercent / 100, pressureColor)])
            MenuKV(label: "Pressure", value: String(format: "%.0f%%", m.pressurePercent), color: pressureColor)
            MenuKV(label: "App Memory", value: memSize(m.appMemoryBytes))
            MenuKV(label: "Cached Files", value: memSize(m.cachedFilesBytes))

            if m.swapTotalBytes > 0 {
                Divider()
                MenuSectionHeader("Swap")
                MenuStackedBar(segments: [(Double(m.swapUsedBytes) / Double(m.swapTotalBytes), wired)])
                Text(String(format: "%.2f GB of %.2f GB", m.swapUsedGB, Double(m.swapTotalBytes) / 1_073_741_824))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
            }

            Divider()
            MenuSectionHeader("Pages / sec")
            MenuKV(label: "Page-ins", value: pagesRate(monitor.memoryPageInRate))
            MenuKV(label: "Page-outs", value: pagesRate(monitor.memoryPageOutRate))
            MenuKV(label: "Swap-ins", value: pagesRate(monitor.memorySwapInRate))
            MenuKV(label: "Swap-outs", value: pagesRate(monitor.memorySwapOutRate),
                   color: monitor.memorySwapOutRate > 0 ? Theme.heat(1) : Theme.text)

            Divider()
            MenuSectionHeader("Top by Memory")
            let topMem = Dictionary(grouping: monitor.snapshot.processes, by: \.name)
                .map { (name: $0.key, bytes: $0.value.reduce(UInt64(0)) { $0 + $1.memoryBytes }) }
                .sorted { $0.bytes > $1.bytes }
                .prefix(5)
            ForEach(Array(topMem), id: \.name) { entry in
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(memSize(entry.bytes))
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.dim)
                }
            }
            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }
}

struct NETMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    private let green = Color(red: 0.40, green: 0.82, blue: 0.55)
    var body: some View {
        let n = monitor.snapshot.network
        let ifaces = InterfaceSampler.sample()
        let connected = ifaces.filter { $0.isConnected }
        let notConnected = ifaces.filter { !$0.isConnected }
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader("Network")
            ForEach(connected) { i in
                HStack(spacing: 6) {
                    Image(systemName: ifaceIcon(i)).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                        if let ip = i.ipv4 {
                            Text(ip).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Connected").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(green)
                }
            }
            Divider()
            MenuKV(label: "↓ Download", value: formatRate(n.downloadBytesPerSec), color: MetricPalette.downC)
            Sparkline(values: monitor.history.netDown, color: MetricPalette.downC, height: 22)
            MenuKV(label: "↑ Upload", value: formatRate(n.uploadBytesPerSec), color: MetricPalette.upC)
            Sparkline(values: monitor.history.netUp, color: MetricPalette.upC, height: 22)
            HStack {
                Text("Peak ↓ \(formatRate(monitor.history.netDown.max() ?? 0))")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
                Spacer()
                Text("Peak ↑ \(formatRate(monitor.history.netUp.max() ?? 0))")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            if !notConnected.isEmpty {
                Divider()
                MenuSectionHeader("Not Connected")
                ForEach(notConnected) { i in
                    Text(i.name).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.dim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }

    private func ifaceIcon(_ i: InterfaceInfo) -> String {
        let n = i.name.lowercased()
        if n.contains("wi-fi") || n.contains("wifi") || n.contains("airport") { return "wifi" }
        if n.contains("thunderbolt") || n.contains("bridge") { return "bolt.horizontal" }
        return "cable.connector"
    }
}

struct SSDMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    private let cyan = Color(red: 0.32, green: 0.82, blue: 0.86)
    var body: some View {
        let d = monitor.snapshot.disk
        let vols = VolumeSampler.sample()
        let local = vols.filter { $0.isLocal }
        let net = vols.filter { !$0.isLocal }
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader("Disks")
            ForEach(local) { v in volumeRow(v) }
            if !net.isEmpty {
                Divider()
                MenuSectionHeader("Network Disks")
                ForEach(net) { v in volumeRow(v) }
            }
            Divider()
            MenuSectionHeader("Activity")
            MenuKV(label: "Read", value: formatRate(d.readBytesPerSec), color: MetricPalette.downC)
            Sparkline(values: monitor.history.diskRead, color: MetricPalette.downC, height: 22)
            MenuKV(label: "Write", value: formatRate(d.writeBytesPerSec), color: MetricPalette.upC)
            Sparkline(values: monitor.history.diskWrite, color: MetricPalette.upC, height: 22)
            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }

    private func volumeRow(_ v: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: v.isLocal ? "internaldrive" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                Text(v.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(iStatBytes(UInt64(max(0, v.freeBytes)))) free")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(cyan).frame(width: max(2, geo.size.width * v.usedFraction))
                }
            }.frame(height: 5)
        }
    }
}

// MARK: - Sensors dropdown (iStat "SENSORS" panel: temps + fans + power)

struct SensorsMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false

    var body: some View {
        let s = monitor.snapshot
        let temp = s.temperature
        let thermal = s.thermal
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionHeader("Sensors")

            if temp.groups.isEmpty {
                Text("no sensors available")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            } else {
                MenuSectionHeader("Temperatures")
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(temp.groups) { group in
                            HStack {
                                Text(group.category.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(0.5).foregroundStyle(Theme.faint)
                                Spacer()
                                Text("avg \(formatTemperature(group.average, fahrenheit: fahrenheit)) · max \(formatTemperature(group.maximum, fahrenheit: fahrenheit))")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.faint)
                            }
                            ForEach(group.sensors) { sensor in
                                SensorTempRow(name: sensor.name, celsius: sensor.celsius, fahrenheit: fahrenheit)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            HStack {
                MenuSectionHeader("Fans")
                if thermal.hasFans {
                    Text(thermal.pressure.rawValue.capitalized)
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
                }
            }
            if thermal.hasFans {
                ForEach(Array(thermal.fanRPMs.enumerated()), id: \.offset) { idx, rpm in
                    SensorFanRow(label: fanLabel(idx, count: thermal.fanRPMs.count), rpm: rpm)
                }
            } else {
                Text("Fanless").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            }

            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }

    private func fanLabel(_ idx: Int, count: Int) -> String {
        if count == 2 { return idx == 0 ? "Left Fan" : "Right Fan" }
        return "Fan \(idx + 1)"
    }
}

/// Sensor temperature row: name (left) + reading + a heat-colored bar (iStat style).
struct SensorTempRow: View {
    let name: String, celsius: Double, fahrenheit: Bool
    var body: some View {
        let heat = min(1, celsius / 100)
        HStack(spacing: 8) {
            Text(name).font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(formatTemperature(celsius, fahrenheit: fahrenheit))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.heat(heat)).frame(width: 44, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(Theme.heat(heat)).frame(width: max(2, 60 * min(1, celsius / 110)))
            }.frame(width: 60, height: 5)
        }
    }
}

/// Fan row: label (left) + rpm + a bar normalized to a typical ceiling.
struct SensorFanRow: View {
    let label: String, rpm: Double
    private let ceiling = 6500.0
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
            Spacer(minLength: 4)
            Text(String(format: "%.0f rpm", rpm))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                .frame(width: 70, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(MetricPalette.downC).frame(width: max(2, 60 * min(1, rpm / ceiling)))
            }.frame(width: 60, height: 5)
        }
    }
}

// MARK: - Battery dropdown (iStat "BATTERY" panel: charge + health + power)

private func wattStr(_ w: Double) -> String { String(format: "%.2f W", w) }

struct BatteryMenuDropdown: View {
    let monitor: SiliconScopeMonitor
    var body: some View {
        let s = monitor.snapshot
        let b = s.battery
        let chargeColor: Color = b.isCharging ? MetricPalette.gpuC
            : (b.percent <= 20 ? Theme.heat(1) : Theme.text)
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionHeader("Battery")

            if b.hasBattery {
                HStack {
                    Text(b.stateLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text("\(Int(b.percent.rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(chargeColor)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    GeometryReader { geo in
                        Capsule().fill(chargeColor).frame(width: max(2, geo.size.width * b.percent / 100))
                    }
                }.frame(height: 7)

                Divider()
                MenuKV(label: "Health", value: b.healthPercent > 0 ? "\(Int(b.healthPercent.rounded()))%" : "—")
                MenuKV(label: "Cycles", value: "\(b.cycleCount)")
                MenuKV(label: "Condition", value: b.condition.isEmpty ? "—" : b.condition,
                       color: b.condition == "Normal" ? Theme.text : Theme.heat(1))
            } else {
                Text("No battery (desktop Mac)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            }

            Divider()
            MenuSectionHeader("Power")
            let pmax = 50.0
            MenuMeterRow(label: "CPU", value: wattStr(s.power.cpuWatts),
                         fraction: s.power.cpuWatts / pmax, color: Color(nsColor: MetricPalette.pCPU))
            MenuMeterRow(label: "GPU", value: wattStr(s.power.gpuWatts),
                         fraction: s.power.gpuWatts / pmax, color: MetricPalette.gpuC)
            if s.power.aneWatts > 0.05 {
                MenuMeterRow(label: "ANE", value: wattStr(s.power.aneWatts),
                             fraction: s.power.aneWatts / pmax, color: MetricPalette.aneC)
            }
            if s.power.dramWatts > 0.05 {
                MenuMeterRow(label: "DRAM", value: wattStr(s.power.dramWatts),
                             fraction: s.power.dramWatts / pmax, color: MetricPalette.downC)
            }
            HStack {
                Text("Total (SoC)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                Spacer()
                Text(wattStr(s.power.socWatts))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
            }

            let energy = s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
            if !energy.isEmpty {
                Divider()
                MenuSectionHeader("Apps Using Energy")
                ForEach(Array(energy)) { proc in
                    HStack(spacing: 6) {
                        Text(proc.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f%%", proc.cpuPercent))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                }
            }

            Divider()
            OpenDashboardButton()
        }
        .padding(12).frame(width: 260).background(Theme.bg).foregroundStyle(Theme.text)
    }
}
