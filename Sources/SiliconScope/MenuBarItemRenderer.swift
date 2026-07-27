//
//  File:      MenuBarItemRenderer.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Turns a `MenuBarItemConfig` into the three things a status item needs: its glyph
//             image, the cheap signature that decides whether the glyph must be re-rasterized, and
//             the SwiftUI dropdown. Replaces the static 8-entry `Spec` array in MetricBarController
//             where every metric was welded to exactly one render mode and one data selection
//             (#27, docs/design-system.md §4).
//  Notes:     ⚠️ The `metric × defaultMode × defaultChannels` combinations MUST reproduce the
//             retired Spec array pixel for pixel — a migrated install renders the same menu bar it
//             had before the upgrade. The signature strings keep their old ids ("cpu", "mem", …)
//             for the same reason: a changed id would force one needless re-rasterize per item on
//             first launch, and they are what MenuBarSignatureTests pins.
//             ⚠️ `Channel.value/fraction/series` are the ONLY place a DataChannel meets the
//             monitor. Adding a channel means adding it here, and the compiler enforces that via
//             exhaustive switches.
//             Sensors resolve their second reading at sample time (GPU temperature when the
//             machine reports one, battery temperature otherwise), so that channel's prefix comes
//             from the sample, never from the model.
//
import AppKit
import SwiftUI
import SiliconScopeCore

/// Main-actor isolated: every entry point reads the live `SiliconScopeMonitor`, and rendering
/// happens on the tick that `MetricBarController` already runs there.
@MainActor
enum MenuBarItemRenderer {

    // MARK: - Public surface

    /// The glyph image for an item, drawn for the menu bar's real appearance.
    static func glyph(_ config: MenuBarItemConfig, _ m: SiliconScopeMonitor, dark: Bool) -> NSImage {
        switch config.mode {
        case .composite:
            return MenuBarIcon.glyph(for: m, dark: dark)

        case .bars:
            return MenuBarGlyph.bars(label: config.metric.glyphLabel,
                                     values: config.channels.map { fraction($0, m) },
                                     colors: config.channels.map { color($0) },
                                     dark: dark)

        case .graph:
            return MenuBarGlyph.line(label: config.metric.glyphLabel,
                                     series: graphSeries(config, m).map { ($0.values, $0.color) },
                                     dark: dark)

        case .twoLine:
            let rows = resolvedRows(config, m)
            return MenuBarGlyph.twoLine(label: config.metric.glyphLabel,
                                        prefix1: rows[0].prefix, value1: rows[0].value,
                                        prefix2: rows[1].prefix, value2: rows[1].value,
                                        dark: dark, reserveValue: reserveTemplate(config))

        case .value:
            let row = resolvedRows(config, m)[0]
            return MenuBarGlyph.oneLine(label: config.metric.glyphLabel,
                                        prefix: row.prefix, value: row.value,
                                        dark: dark, reserveValue: reserveTemplate(config))

        case .icon:
            let b = m.snapshot.battery
            return MenuBarGlyph.battery(percent: b.percent, charging: b.isCharging,
                                        plugged: b.isPluggedIn, dark: dark)
        }
    }

    /// Cheap signature of everything that changes the glyph's pixels. Re-rasterizing on every tick
    /// is what docs/energy-optimization.md FIX 3 removed, so this must cover every input `glyph`
    /// reads — appearance, scale, and each channel's quantized value.
    static func signature(_ config: MenuBarItemConfig, _ m: SiliconScopeMonitor, dark: Bool) -> String {
        let scale = Double(UIScale.glyph)
        let id = signatureID(config)
        switch config.mode {
        case .composite:
            return MenuBarIcon.signature(for: m, dark: dark)

        case .bars:
            return MenuBarSignature.bars(id, config.channels.map { fraction($0, m) }, dark: dark, scale: scale)

        case .graph:
            // The whole visible window matters: the chart redraws when any sample in it moves, and
            // every series is part of the same picture.
            let visible = graphSeries(config, m).flatMap { Array($0.values.suffix(30)) }
            return MenuBarSignature.bars(id, visible, dark: dark, scale: scale)

        case .twoLine, .value:
            let rows = resolvedRows(config, m)
            let visible = config.mode == .value ? Array(rows.prefix(1)) : rows
            // Prefixes are part of the signature: the sensor row's prefix changes with the machine's
            // reported sensors, and a prefix change moves the value column.
            return MenuBarSignature.text(id, visible.flatMap { [$0.prefix, $0.value] }, dark: dark, scale: scale)

        case .icon:
            let b = m.snapshot.battery
            return MenuBarSignature.text(id, ["\(Int(b.percent.rounded()))", b.isCharging ? "c" : "", b.isPluggedIn ? "p" : ""],
                                         dark: dark, scale: scale)
        }
    }

    /// The dropdown is a property of the METRIC, not of the render mode: two items of the same
    /// metric in different modes open the same panel.
    static func dropdown(_ config: MenuBarItemConfig, _ m: SiliconScopeMonitor) -> AnyView {
        switch config.metric {
        case .combined: return AnyView(MenuBarView(monitor: m))
        case .cpu:      return AnyView(CPUMenuDropdown(monitor: m))
        case .gpu:      return AnyView(GPUMenuDropdown(monitor: m))
        case .memory:   return AnyView(MEMMenuDropdown(monitor: m))
        case .network:  return AnyView(NETMenuDropdown(monitor: m))
        case .disk:     return AnyView(SSDMenuDropdown(monitor: m))
        case .sensors:  return AnyView(SensorsMenuDropdown(monitor: m))
        case .battery:  return AnyView(BatteryMenuDropdown(monitor: m))
        }
    }

    // MARK: - Rows

    private struct Row { let prefix: String; let value: String }

    /// Two rows, padded so `twoLine` always has both. A config that reaches here is `isValid` (the
    /// store repairs on load), so the padding only guards hand-edited defaults.
    private static func resolvedRows(_ config: MenuBarItemConfig, _ m: SiliconScopeMonitor) -> [Row] {
        var rows = config.channels.map { Row(prefix: prefix($0, m), value: value($0, m)) }
        while rows.count < 2 { rows.append(Row(prefix: "", value: "")) }
        return rows
    }

    /// Widest of the item's channel templates: the value column must not resize when the two rows
    /// carry different units.
    private static func reserveTemplate(_ config: MenuBarItemConfig) -> String {
        config.channels
            .map(\.reserveTemplate)
            .max(by: { $0.count < $1.count }) ?? "999.9 GB"
    }

    /// Signature ids of the retired Spec array, so an upgrade doesn't invalidate every glyph.
    /// Items the user adds later key off their instance id instead — two items of one metric must
    /// not share a signature slot.
    private static func signatureID(_ config: MenuBarItemConfig) -> String {
        switch config.metric {
        case .combined: return "ss"
        case .cpu:      return "cpu"
        case .gpu:      return "gpu"
        case .memory:   return "mem"
        case .network:  return "net"
        case .disk:     return "ssd"
        case .sensors:  return "sen"
        case .battery:  return "bat"
        }
    }

    // MARK: - Channel → data

    /// Prefix drawn beside the value. Comes from the model except where the reading itself decides
    /// it — `sensorSecondaryTemp` is "G"pu on a machine that reports GPU temperature and "B"attery
    /// otherwise, which a static string would get wrong on one of the two kinds of Mac.
    private static func prefix(_ channel: DataChannel, _ m: SiliconScopeMonitor) -> String {
        guard channel.resolvesAtSampleTime else { return channel.prefix }
        let t = m.snapshot.temperature
        return t.gpuCelsius > 0 ? "G" : "B"
    }

    /// The channel's display string.
    private static func value(_ channel: DataChannel, _ m: SiliconScopeMonitor) -> String {
        let s = m.snapshot
        switch channel {
        case .socPower:        return String(format: "%.1f W", s.power.socWatts)
        case .cpuEfficiency:   return percent(s.cpu.eUsage)
        case .cpuPerformance:  return percent(s.cpu.pUsage)
        case .gpuUtilisation:  return percent(s.gpu.usage)
        case .gpuMemory:       return iStatGB(s.gpu.inUseMemoryGB)
        case .mediaThroughput: return String(format: "%.0f GB/s", s.bandwidth.mediaGBs)
        case .anePower:        return String(format: "%.1f W", s.power.aneWatts)
        case .memoryUsed:      return iStatGB(s.memory.usedGB)
        case .memoryFree:      return iStatGB(s.memory.freeGB)
        case .memoryPressure:  return String(format: "%.0f%%", s.memory.pressurePercent)
        case .networkDown:     return iStatRate(s.network.downloadBytesPerSec)
        case .networkUp:       return iStatRate(s.network.uploadBytesPerSec)
        case .diskUsed:        return iStatBytes(s.disk.totalBytes - s.disk.freeBytes)
        case .diskFree:        return iStatBytes(s.disk.freeBytes)
        case .diskRead:        return iStatRate(s.disk.readBytesPerSec)
        case .diskWrite:       return iStatRate(s.disk.writeBytesPerSec)
        case .sensorPrimaryTemp, .sensorSecondaryTemp:
            let f = UserDefaults.standard.bool(forKey: "temperatureFahrenheit")
            let t = m.snapshot.temperature
            if channel == .sensorPrimaryTemp {
                return tempGlyphValue(t.cpuMaxCelsius > 0 ? t.cpuMaxCelsius : t.cpuCelsius, f)
            }
            return tempGlyphValue(t.gpuCelsius > 0 ? t.gpuCelsius : t.batteryCelsius, f)
        case .batteryPercent:  return String(format: "%.0f%%", s.battery.percent)
        }
    }

    /// The channel as a 0...1 bar fill.
    ///
    /// ⚠️ Rate channels have NO ceiling to fill against, so they return 0 rather than an invented
    /// number — and `MetricKind.supportedModes` never offers `bars` for a rate metric,
    /// so this is unreachable rather than merely harmless.
    private static func fraction(_ channel: DataChannel, _ m: SiliconScopeMonitor) -> Double {
        let s = m.snapshot
        switch channel {
        case .socPower:        return 0
        case .cpuEfficiency:   return s.cpu.eUsage
        case .cpuPerformance:  return s.cpu.pUsage
        case .gpuUtilisation:  return s.gpu.usage
        case .gpuMemory:       return s.gpu.inUseMemoryFraction
        case .mediaThroughput: return min(1, s.bandwidth.mediaGBs / max(m.mediaPeakGBs, 0.5))
        case .anePower:        return min(1, s.power.aneWatts / max(m.anePeakWatts, 0.1))
        case .memoryUsed:      return s.memory.usedFraction
        case .memoryFree:      return 1 - s.memory.usedFraction
        case .memoryPressure:  return s.memory.pressurePercent / 100
        case .networkDown, .networkUp, .diskRead, .diskWrite:
            return 0
        case .diskUsed:        return s.disk.usedFraction
        case .diskFree:        return 1 - s.disk.usedFraction
        case .sensorPrimaryTemp, .sensorSecondaryTemp, .batteryPercent:
            return channel == .batteryPercent ? s.battery.percent / 100 : 0
        }
    }

    // MARK: - Graph series

    private struct GraphSeries { let values: [Double]; let color: NSColor }

    /// The item's series for `.graph`, each normalised to 0...1.
    ///
    /// ⚠️ Channels with no ceiling share ONE maximum across the item. Normalising ↓ and ↑
    /// separately would make both peak at full height and erase the fact that one is ten times the
    /// other — the chart would say "both busy" no matter the traffic.
    private static func graphSeries(_ config: MenuBarItemConfig, _ m: SiliconScopeMonitor) -> [GraphSeries] {
        let raw = config.channels.map { (channel: $0, values: rawSeries($0, m)) }
        let sharedPeak = raw.filter { scalesToWindow($0.channel) }.flatMap(\.values).max() ?? 0
        return raw.map { entry in
            guard scalesToWindow(entry.channel) else {
                return GraphSeries(values: entry.values, color: color(entry.channel))
            }
            let scaled = sharedPeak > 0 ? entry.values.map { min(1, max(0, $0) / sharedPeak) }
                                        : entry.values.map { _ in 0.0 }
            return GraphSeries(values: scaled, color: color(entry.channel))
        }
    }

    /// True when the channel has no ceiling of its own and must be scaled against the window.
    private static func scalesToWindow(_ channel: DataChannel) -> Bool {
        switch channel {
        case .networkDown, .networkUp, .diskRead, .diskWrite, .socPower: return true
        default: return false
        }
    }

    /// History for a channel. Series that HAVE a ceiling arrive already at 0...1; the ceiling-less
    /// ones arrive raw, for `graphSeries` to scale together.
    private static func rawSeries(_ channel: DataChannel, _ m: SiliconScopeMonitor) -> [Double] {
        let h = m.history
        switch channel {
        case .cpuEfficiency:   return h.eCPU
        case .cpuPerformance:  return h.pCPU
        case .gpuUtilisation:  return h.gpu
        case .gpuMemory:       return h.gpuMem
        case .mediaThroughput: return h.media.map { min(1, $0 / max(m.mediaPeakGBs, 0.5)) }
        case .anePower:        return h.ane.map { min(1, $0 / max(m.anePeakWatts, 0.1)) }
        case .memoryUsed:      return h.memFraction
        case .memoryFree:      return h.memFraction.map { 1 - $0 }
        // `dieTemp` is fed from `temperature.cpuCelsius` — the CPU sensor, which is this channel.
        // Scaled against the app's own hot reference rather than the window, so the line means
        // thermal headroom and a machine idling at 45 °C does not look like one at its limit.
        case .sensorPrimaryTemp: return h.dieTemp.map { min(1, $0 / Theme.hotCelsius) }
        // Raw — no ceiling exists. `graphSeries` scales these against the window.
        case .networkDown:     return h.netDown
        case .networkUp:       return h.netUp
        case .diskRead:        return h.diskRead
        case .diskWrite:       return h.diskWrite
        case .socPower:        return h.soc
        // No series exists for disk space, the second sensor reading, memory pressure or battery %
        // — `DataChannel.hasHistory` says so, and `channels(for: .graph)` filters them out.
        case .memoryPressure, .diskUsed, .diskFree, .sensorSecondaryTemp, .batteryPercent:
            return []
        }
    }

    private static func color(_ channel: DataChannel) -> NSColor {
        switch channel {
        case .cpuEfficiency:   return MetricPalette.eCPU
        case .cpuPerformance:  return MetricPalette.pCPU
        case .gpuUtilisation:  return MetricPalette.gpu
        case .gpuMemory:       return MetricPalette.gpuMem
        case .mediaThroughput: return MetricPalette.media
        case .anePower:        return MetricPalette.ane
        case .networkDown, .diskRead:  return MetricPalette.down
        case .networkUp, .diskWrite:   return MetricPalette.up
        default:               return MetricPalette.pCPU
        }
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}
