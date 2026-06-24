//
//  File:      MenuBarIcon.swift
//  Created:   2026-06-16
//  Updated:   2026-06-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The live menu-bar glyph used as the MenuBarExtra label: six mini bars —
//             CPU / GPU / ANE / Media Engine / Memory-usage / Memory-bandwidth — that track
//             real-time utilization, and turn the whole glyph red (blinking) on an alert
//             (memory swapping, memory-pressure critical, or GPU throttling).
//  Notes:     The bars are drawn into an NSImage with Core Graphics and handed to
//             MenuBarExtra as `Image(nsImage:)`. A live SwiftUI View (HStack/Canvas/
//             TimelineView) as a MenuBarExtra label does NOT reliably convert to a status
//             item image (it collapses to zero width and vanishes) — a real bitmap does.
//             The view re-reads the monitor inside `body`, so @Observable updates re-run
//             body and refresh the glyph (the same mechanism that updates the dropdown).
//             Normal state uses a template image (auto light/dark tint); the alert state
//             draws real red (non-template) and blinks at the sample cadence (~1s) via
//             sample-count parity. Each bar is a 0...1 fraction:
//               CPU  = cpu.pUsage (P-cores — what heavy/AI work loads)
//               GPU  = gpu.usage
//               ANE  = aneWatts / anePeakWatts (no public utilization API → power proxy)
//               MEDIA= mediaGBs / mediaPeakGBs (Media Engine bandwidth proxy)
//               MEM  = memory.usedFraction (unified-memory used)
//               MEMBW= totalGBs / observed bandwidthPeak (achievable BW is ~half the
//                      theoretical ceiling on M1 Max — normalizing to spec looks dead)
//
import SwiftUI
import AppKit
import SiliconScopeCore

struct MenuBarIcon: View {
    let monitor: SiliconScopeMonitor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Reading the monitor inside body establishes the @Observable dependency, so
        // body re-runs (and the glyph refreshes) on every sample. colorScheme tracks the
        // menu-bar appearance so the label/track stay visible on a light menu bar too.
        Image(nsImage: Self.glyph(for: monitor, dark: colorScheme == .dark))
    }

    /// Per-metric bar colors (CPU / GPU / ANE / Media / MEM usage / Mem BW) — a fixed
    /// legend the dropdown mirrors, so the glyph is self-documenting.
    static let barColors: [NSColor] = [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 0.98, alpha: 1),  // CPU    blue
        NSColor(srgbRed: 0.40, green: 0.82, blue: 0.55, alpha: 1),  // GPU    green
        NSColor(srgbRed: 0.74, green: 0.53, blue: 0.99, alpha: 1),  // ANE    purple
        NSColor(srgbRed: 0.98, green: 0.62, blue: 0.30, alpha: 1),  // Media  orange
        NSColor(srgbRed: 0.93, green: 0.46, blue: 0.66, alpha: 1),  // MEM    pink
        NSColor(srgbRed: 0.32, green: 0.82, blue: 0.86, alpha: 1),  // Mem BW cyan
    ]

    static func glyph(for monitor: SiliconScopeMonitor, dark: Bool) -> NSImage {
        let s = monitor.snapshot
        let values: [Double] = [
            s.cpu.pUsage,
            s.gpu.usage,
            min(1, s.power.aneWatts / max(monitor.anePeakWatts, 0.1)),
            min(1, s.bandwidth.mediaGBs / max(monitor.mediaPeakGBs, 0.5)),
            s.memory.usedFraction,                  // MEM usage (5th)
            min(1, s.bandwidth.totalGBs / max(monitor.bandwidthPeakGBs, 1)),  // Mem BW vs observed peak (6th)
        ]
        let alert = monitor.memoryRisk == .swapping
            || monitor.gpuThrottling
            || s.memory.pressure == .critical
        // Blink: dim every other sample while alerting (sample count advances each tick).
        let blinkDim = alert && (monitor.history.gpu.count % 2 == 1)

        let height: CGFloat = 18
        let barW: CGFloat = 6.5, gap: CGFloat = 2.0   // bar width doubled (was 3.4)
        let radius: CGFloat = 1.2
        let n = CGFloat(values.count)
        let barsW = barW * n + gap * (n - 1)
        // Label + track follow the menu-bar appearance (white on dark, black on light) so
        // they stay visible either way; the value bars keep their fixed metric colors.
        let inkColor = dark ? NSColor.white : NSColor.black
        let track = inkColor.withAlphaComponent(0.16)  // always-visible column slot

        // "SS" identifier stacked vertically to the left of the bars (iStat draws its
        // per-graph label like that — "C/P/U" stacked).
        let letter = "S" as NSString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: inkColor.withAlphaComponent(0.9),
        ]
        let charSize = letter.size(withAttributes: labelAttrs)
        let labelColW = ceil(charSize.width)
        let labelGap: CGFloat = 3
        let originX = labelColW + labelGap
        let width = ceil(originX + barsW) + 1
        let half = height / 2
        let charX = (labelColW - charSize.width) / 2
        let charY = max(0, (half - charSize.height) / 2)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Left "SS" label — two letters stacked (top half / bottom half).
            letter.draw(at: NSPoint(x: charX, y: half + charY), withAttributes: labelAttrs)
            letter.draw(at: NSPoint(x: charX, y: charY), withAttributes: labelAttrs)
            // Bars: full-height track + value fill in the metric color (red while alerting).
            for (i, v) in values.enumerated() {
                let x = originX + CGFloat(i) * (barW + gap)
                track.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: height),
                             xRadius: radius, yRadius: radius).fill()
                let h = max(2.5, height * CGFloat(min(1, max(0, v))))
                let color: NSColor = alert
                    ? (blinkDim ? NSColor.systemRed.withAlphaComponent(0.25) : NSColor.systemRed)
                    : Self.barColors[i]
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h),
                             xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = false   // colored glyph — never template
        return image
    }
}
