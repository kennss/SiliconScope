//
//  File:      Theme.swift
//  Created:   2026-06-08
//  Updated:   2026-06-12
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Shared visual language and reusable UI atoms (Card, Bar, KV, Sparkline).
//             Restrained instrument-panel look: one accent, muted heat colors, dense
//             monospaced typography. All in-app text is English.
//  Notes:     Theme.heat(fraction) maps 0...1 load to green/amber/red. Cards are
//             neutral (no per-card colors) so data — not chrome — carries the eye.
//             Bottleneck.color lives here (UI layer) so KtopCore stays SwiftUI-free.
//
import SwiftUI
import Charts
import KtopCore

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

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Theme.faint)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A thin labelled progress bar (0...1).
struct Bar: View {
    let label: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
                    Capsule().fill(Theme.heat(value))
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

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), .clear],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", index), y: .value("v", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
    }
}
