//
//  File:      MenuBarItemConfig.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The menu-bar item model for #27: a user-ordered LIST of item instances, replacing
//             the static 8-entry Spec array in MetricBarController where each metric was welded
//             to exactly one render mode and one data selection.
//             Lives in Core (no UI) so the model, its validation and the migration off the legacy
//             per-metric Bools are unit-testable — the app target has no test target.
//  Notes:     A metric can appear MORE THAN ONCE with different modes; identity is the instance
//             UUID, not the metric. `channels` is an array because arity depends on the mode
//             (twoLine needs exactly 2, value needs 1, bars takes N) and because GPU composes
//             three heterogeneous sources with different normalisers.
//             Every DataChannel carries its own reserveTemplate: without a worst-case width the
//             glyph's width changes as values grow and shoves every item to its left.
//
import Foundation

// MARK: - Metric

/// A menu-bar item's subject. Mirrors the dashboard cards.
public enum MetricKind: String, Codable, CaseIterable, Sendable {
    /// The combined "SS" cockpit glyph. An EXPLICIT EXCEPTION, not a normal metric: it is drawn by
    /// its own renderer (a 6-bar composite with its own label font, colour table and alert/blink
    /// override) and cannot be reproduced by any `GlyphMode`. Modelling it as `.bars` would change
    /// what today's users see, so it keeps a dedicated mode and a fixed channel set.
    case combined
    case cpu, gpu, memory, network, disk, sensors, battery

    /// How the metric's values behave, which is what decides the modes it can offer.
    public enum Family { case usage, rate, state }

    public var family: Family {
        switch self {
        case .combined:                 return .usage
        case .cpu, .gpu, .memory:       return .usage
        case .network:                  return .rate
        case .disk:                     return .rate
        case .sensors, .battery:        return .state
        }
    }

    /// Modes this metric can actually render, derived from the data that EXISTS — not from what
    /// would be nice. `MetricsEngine.History` carries soc/pCPU/eCPU/gpu/gpuMem/ane/media/bandwidth/
    /// dieTemp/memory/memFraction/netDown/netUp/diskRead/diskWrite, and nothing else:
    ///
    /// - there is no history series for disk *space*, per-sensor temperature or battery %, so
    ///   `histogram` is not offered there;
    /// - the rate series are not 0...1 and `MenuBarGlyph.histogram` only clamps — it has no
    ///   auto-scaler — so rate metrics do not get `histogram` until one exists;
    /// - `bars` is never offered for a rate: a fill bar of "MB/s" would be a lie, because there is
    ///   no ceiling to fill against. The type system enforces the product's no-invented-numbers rule.
    public var supportedModes: [GlyphMode] {
        switch self {
        case .combined:               return [.composite]
        case .cpu, .gpu, .memory:     return [.bars, .histogram, .twoLine, .value]
        case .network:                return [.twoLine, .value]
        case .disk:                   return [.twoLine, .value]
        case .sensors:                return [.twoLine, .value]
        case .battery:                return [.icon, .value, .twoLine]
        }
    }

    /// Channels this metric can draw from.
    public var channels: [DataChannel] {
        switch self {
        case .combined: return [.socPower]
        case .cpu:      return [.cpuEfficiency, .cpuPerformance]
        case .gpu:      return [.gpuUtilisation, .mediaThroughput, .anePower, .gpuMemory]
        case .memory:   return [.memoryUsed, .memoryFree, .memoryPressure]
        case .network:  return [.networkDown, .networkUp]
        case .disk:     return [.diskUsed, .diskFree, .diskRead, .diskWrite]
        case .sensors:  return [.sensorPrimaryTemp, .sensorSecondaryTemp]
        case .battery:  return [.batteryPercent]
        }
    }

    /// The two-letter-ish stacked label drawn before the glyph ("C/P/U").
    public var glyphLabel: String {
        switch self {
        case .combined: return "SS"
        case .cpu:      return "CPU"
        case .gpu:      return "GPU"
        case .memory:   return "MEM"
        case .network:  return "NET"
        case .disk:     return "SSD"
        case .sensors:  return "SEN"
        case .battery:  return "BAT"
        }
    }

    /// Full name, for Settings and the add menu. `glyphLabel` is the 2–3 character form the menu
    /// bar draws and is too terse to pick from a list.
    public var settingsLabel: String {
        switch self {
        case .combined: return "Combined cockpit"
        case .cpu:      return "CPU"
        case .gpu:      return "GPU / Media / Neural"
        case .memory:   return "Memory"
        case .network:  return "Network"
        case .disk:     return "Disk"
        case .sensors:  return "Sensors"
        case .battery:  return "Battery"
        }
    }

    /// What the item renders when the user first adds it — today's hardcoded behaviour, so that
    /// migrating an existing install changes nothing on screen.
    public var defaultMode: GlyphMode {
        switch self {
        case .combined:            return .composite
        case .cpu, .gpu:           return .bars
        case .memory, .network,
             .disk, .sensors:      return .twoLine
        case .battery:             return .icon
        }
    }

    /// The channel set matching `defaultMode`, again reproducing today's glyphs exactly.
    public var defaultChannels: [DataChannel] {
        switch self {
        case .combined: return [.socPower]
        case .cpu:      return [.cpuEfficiency, .cpuPerformance]
        case .gpu:      return [.gpuUtilisation, .mediaThroughput, .anePower]
        case .memory:   return [.memoryUsed, .memoryFree]
        case .network:  return [.networkDown, .networkUp]
        case .disk:     return [.diskUsed, .diskFree]
        case .sensors:  return [.sensorPrimaryTemp, .sensorSecondaryTemp]
        case .battery:  return [.batteryPercent]
        }
    }
}

// MARK: - Mode

/// How an item is drawn. Each case maps to a renderer that already exists in `MenuBarGlyph` —
/// including `histogram`, which was fully built but unreachable because every metric was welded to
/// one mode.
public enum GlyphMode: String, Codable, CaseIterable, Sendable {
    /// Stacked label + thick value bars, one per channel.
    case bars
    /// Stacked label + a mini history histogram.
    case histogram
    /// Stacked label + two "prefix … value" rows.
    case twoLine
    /// Stacked label + a single value.
    case value
    /// A drawn icon (battery body + percentage).
    case icon
    /// The combined "SS" renderer. Not selectable for any other metric.
    case composite

    /// How many channels this mode consumes. `mode × channel` is NOT a well-formed cartesian
    /// product — twoLine draws exactly two rows and value draws exactly one — so arity is part of
    /// the model rather than something the UI has to remember.
    public var arity: ClosedRange<Int> {
        switch self {
        case .bars:      return 1...4
        case .histogram: return 1...1
        case .twoLine:   return 2...2
        case .value:     return 1...1
        case .icon:      return 1...1
        case .composite: return 1...1
        }
    }

    public var label: String {
        switch self {
        case .bars:      return "Bars"
        case .histogram: return "History graph"
        case .twoLine:   return "Two lines"
        case .value:     return "Value"
        case .icon:      return "Icon"
        case .composite: return "Cockpit"
        }
    }
}

// MARK: - Channel

/// One series an item can draw. Each channel owns the presentation facts that belong to the DATA
/// rather than to the mode: the prefix shown beside it, and the worst-case string used to reserve
/// the value column.
public enum DataChannel: String, Codable, CaseIterable, Sendable {
    case socPower
    case cpuEfficiency, cpuPerformance
    case gpuUtilisation, gpuMemory, mediaThroughput, anePower
    case memoryUsed, memoryFree, memoryPressure
    case networkDown, networkUp
    case diskUsed, diskFree, diskRead, diskWrite
    case sensorPrimaryTemp, sensorSecondaryTemp
    case batteryPercent

    /// Prefix drawn to the left of the value in `twoLine` mode.
    public var prefix: String {
        switch self {
        case .socPower:            return "W"
        case .cpuEfficiency:       return "E"
        case .cpuPerformance:      return "P"
        case .gpuUtilisation:      return "G"
        case .gpuMemory:           return "V"
        case .mediaThroughput:     return "M"
        case .anePower:            return "A"
        case .memoryUsed,
             .diskUsed:            return "U:"
        case .memoryFree,
             .diskFree:            return "F:"
        case .memoryPressure:      return "P:"
        case .networkDown,
             .diskRead:            return "↓"
        case .networkUp,
             .diskWrite:           return "↑"
        // Sensors resolve their prefix at SAMPLE TIME, not from the model: the second reading is
        // GPU temperature when the machine reports one and battery temperature otherwise. A static
        // string here would be wrong on one of the two kinds of Mac.
        case .sensorPrimaryTemp:   return "C"
        case .sensorSecondaryTemp: return ""
        case .batteryPercent:      return ""
        }
    }

    /// ⚠️ Worst-case value string, used to reserve the value column's width.
    ///
    /// Without it the glyph is re-measured every tick and its width changes as values grow and
    /// shrink — which shoves every menu-bar item to its left, every second. This is the axis the
    /// first draft of the model omitted entirely.
    public var reserveTemplate: String {
        switch self {
        case .socPower:                          return "99.9 W"
        case .cpuEfficiency, .cpuPerformance,
             .gpuUtilisation, .memoryPressure:   return "100%"
        case .gpuMemory, .memoryUsed, .memoryFree,
             .diskUsed, .diskFree:               return "999.9 GB"
        case .mediaThroughput:                   return "99 GB/s"
        case .anePower:                          return "99.9 W"
        case .networkDown, .networkUp,
             .diskRead, .diskWrite:              return "999 MB"
        case .sensorPrimaryTemp,
             .sensorSecondaryTemp:               return "99°"
        case .batteryPercent:                    return "100%"
        }
    }

    /// Full name, for the Settings pickers. The `prefix` is a one-character glyph adornment and
    /// says nothing on its own ("P" is both P-cores and pressure, in different metrics).
    public var settingsLabel: String {
        switch self {
        case .socPower:            return "SoC power"
        case .cpuEfficiency:       return "E-cores"
        case .cpuPerformance:      return "P-cores"
        case .gpuUtilisation:      return "GPU"
        case .gpuMemory:           return "GPU memory"
        case .mediaThroughput:     return "Media Engine"
        case .anePower:            return "Neural Engine"
        case .memoryUsed:          return "Used"
        case .memoryFree:          return "Free"
        case .memoryPressure:      return "Pressure"
        case .networkDown:         return "Download"
        case .networkUp:           return "Upload"
        case .diskUsed:            return "Used"
        case .diskFree:            return "Free"
        case .diskRead:            return "Read"
        case .diskWrite:           return "Write"
        case .sensorPrimaryTemp:   return "CPU temperature"
        case .sensorSecondaryTemp: return "GPU / battery temperature"
        case .batteryPercent:      return "Charge"
        }
    }

    /// True when the channel's prefix and source are decided at sample time rather than by the
    /// model — see `sensorSecondaryTemp`.
    public var resolvesAtSampleTime: Bool { self == .sensorSecondaryTemp }
}

// MARK: - Item

/// One menu-bar item instance. A metric may appear several times with different modes; identity is
/// this `id`, never the metric.
public struct MenuBarItemConfig: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var metric: MetricKind
    public var mode: GlyphMode
    public var channels: [DataChannel]

    public init(id: UUID = UUID(), metric: MetricKind, mode: GlyphMode? = nil,
                channels: [DataChannel]? = nil) {
        self.id = id
        self.metric = metric
        self.mode = mode ?? metric.defaultMode
        self.channels = channels ?? metric.defaultChannels
    }

    /// A config is well-formed when the mode is one the metric offers, every channel belongs to
    /// the metric, and the channel count fits the mode's arity.
    public var isValid: Bool {
        guard metric.supportedModes.contains(mode) else { return false }
        guard channels.allSatisfy(metric.channels.contains) else { return false }
        return mode.arity.contains(channels.count)
    }

    /// Repairs an invalid config to the metric's defaults instead of dropping the item — a user's
    /// menu bar should never silently lose an entry because a stored mode was retired.
    public func repaired() -> MenuBarItemConfig {
        isValid ? self : MenuBarItemConfig(id: id, metric: metric)
    }

    /// Stable per-instance autosave name. macOS owns status-item POSITION (users ⌘-drag them and
    /// the system persists the order per autosave name), so the model deliberately carries no
    /// `order` field — an earlier draft had one, and it was unenforceable.
    public var autosaveName: String { "ss.item.\(id.uuidString)" }
}
