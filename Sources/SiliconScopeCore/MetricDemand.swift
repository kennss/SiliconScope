//
//  File:      MetricDemand.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  What one tick is actually asked to measure. `SystemSampler.sample` takes a
//             MetricGroup set — the demand — and reads only those groups; `MetricsEngine.ingest`
//             is told the same set, so a group nobody asked for leaves a GAP in the history
//             instead of a fabricated zero. This is what lets a hidden window stop paying for
//             metrics no one is looking at (#13).
//  Notes:     ⚠️ The load-bearing invariant: DEMAND MUST COVER EVERYTHING ON SCREEN. A group left
//             out of demand keeps its previous value in the published snapshot — carried forward,
//             not re-measured — so putting one on screen would show a stale number as if it were
//             current. Two places decide demand and a new snapshot consumer must add itself to
//             one of them: `MenuBarItemRenderer.demand(for:)` (what a menu-bar glyph reads) and
//             `SiliconScopeMonitor.currentDemand()` (window, alerts, recording, share mode).
//
//             Groups map 1:1 onto SystemSnapshot's stored samples, with two riders:
//               - `aiRuntime` rides with `.processes`; it is derived from the same process table.
//               - `memoryBudget` is arithmetic over `memory` + the AI-runtime RSS, so it recomputes
//                 whenever `.memory` is measured. That RSS is already a ~2.5 s cache (#28 FIX 5),
//                 so the budget was never fresher than the process cadence to begin with.
//
import Foundation

/// A set of metric groups. One bit per independently skippable sampler.
public struct MetricGroup: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let power       = MetricGroup(rawValue: 1 << 0)   // IOReport Energy Model
    public static let cpu         = MetricGroup(rawValue: 1 << 1)   // per-core + cluster residency
    public static let gpu         = MetricGroup(rawValue: 1 << 2)
    public static let bandwidth   = MetricGroup(rawValue: 1 << 3)   // AMCC / PMP
    public static let memory      = MetricGroup(rawValue: 1 << 4)
    public static let thermal     = MetricGroup(rawValue: 1 << 5)   // pressure level
    public static let temperature = MetricGroup(rawValue: 1 << 6)   // SMC + HID sensors
    public static let network     = MetricGroup(rawValue: 1 << 7)
    public static let disk        = MetricGroup(rawValue: 1 << 8)
    public static let battery     = MetricGroup(rawValue: 1 << 9)
    public static let peripherals = MetricGroup(rawValue: 1 << 10)  // Magic devices / AirPods
    public static let processes   = MetricGroup(rawValue: 1 << 11)  // + AI-runtime detection

    public static let all: MetricGroup = [
        .power, .cpu, .gpu, .bandwidth, .memory, .thermal, .temperature,
        .network, .disk, .battery, .peripherals, .processes,
    ]

    /// The floor every tick pays regardless of what is on screen. Both are single instant reads
    /// (`host_statistics64` / thermal pressure) with no sleep and no IOKit walk, and both feed the
    /// alert path — a monitor that stops noticing memory pressure while its window is shut has
    /// stopped being a monitor.
    public static let essential: MetricGroup = [.memory, .thermal]
}

public extension DataChannel {
    /// The group a menu-bar channel reads from. Channels with no series of their own
    /// (`hasHistory == false`) still need their group sampled — they render a live value.
    var metricGroup: MetricGroup {
        switch self {
        case .socPower, .anePower:                       return .power
        case .cpuEfficiency, .cpuPerformance:            return .cpu
        case .gpuUtilisation, .gpuMemory:                return .gpu
        case .mediaThroughput:                           return .bandwidth
        case .memoryUsed, .memoryFree, .memoryPressure:  return .memory
        case .networkDown, .networkUp:                   return .network
        case .diskUsed, .diskFree, .diskRead, .diskWrite: return .disk
        case .sensorPrimaryTemp, .sensorSecondaryTemp:   return .temperature
        case .batteryPercent:                            return .battery
        }
    }
}

public extension Double {
    /// Normalises one history sample against a ceiling, PRESERVING a gap.
    ///
    /// ⚠️ `min(1, .nan)` returns 1 in Swift — every comparison with NaN is false, so the clamp
    /// keeps whichever side is not NaN. Mapped naively over a series, an unmeasured tick would
    /// draw a full-scale spike for a reading that was never taken: the loudest possible way to
    /// render "we did not look".
    func scaledToCeiling(_ ceiling: Double) -> Double {
        isFinite ? Swift.min(1, self / ceiling) : .nan
    }
}

public extension Array where Element == Double {
    /// A history series with its gaps removed.
    ///
    /// ⚠️ Any aggregation over a history series must go through this. A gap is `.nan`, and NaN
    /// does not behave: every comparison with it is false, so `max()` returns whichever side the
    /// implementation happened to keep, and a sum or average is NaN outright. Plotting a NaN is
    /// fine — `Sparkline` breaks the line there, which is the whole point — but reducing one is
    /// how a gap turns into a wrong number on screen.
    var withoutGaps: [Double] { filter(\.isFinite) }
}

public extension SystemSnapshot {
    /// Returns this snapshot with every group it did not measure taken from `previous`.
    ///
    /// ⚠️ What a skipped sampler leaves behind is a zero-initialised struct, and zero is a
    /// reading — 0 W, 0 °C, 0 % — indistinguishable on screen from a machine that went cold.
    /// Carrying the last real value forward keeps the published snapshot honest for the one tick
    /// in which a hidden consumer becomes visible again. It is NOT a substitute for the demand
    /// invariant: a carried value is stale by definition, and the history is told the truth
    /// separately, through `MetricsEngine.ingest(_:dt:measured:)`.
    func carryingForward(_ previous: SystemSnapshot, measured: MetricGroup) -> SystemSnapshot {
        var s = self
        if !measured.contains(.power)       { s.power = previous.power }
        if !measured.contains(.cpu)         { s.cpu = previous.cpu }
        if !measured.contains(.gpu)         { s.gpu = previous.gpu }
        if !measured.contains(.bandwidth)   { s.bandwidth = previous.bandwidth }
        if !measured.contains(.memory)      { s.memory = previous.memory; s.memoryBudget = previous.memoryBudget }
        if !measured.contains(.thermal)     { s.thermal = previous.thermal }
        if !measured.contains(.temperature) { s.temperature = previous.temperature }
        if !measured.contains(.network)     { s.network = previous.network }
        if !measured.contains(.disk)        { s.disk = previous.disk }
        if !measured.contains(.battery)     { s.battery = previous.battery }
        if !measured.contains(.peripherals) { s.peripherals = previous.peripherals }
        // `aiRuntime` is deliberately NOT carried: SystemSampler already hands back its own cached
        // detection when `.processes` is skipped, which is the same object the last full tick used.
        if !measured.contains(.processes)   { s.processes = previous.processes }
        return s
    }
}
