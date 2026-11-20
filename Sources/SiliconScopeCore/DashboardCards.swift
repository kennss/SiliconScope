//
//  File:      DashboardCards.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The dashboard's cards as data: which ones exist, which the user has hidden, and
//             what the dashboard therefore needs measured. Lives in Core (no UI) so the hidden
//             set's persistence and the demand it implies are unit-testable, and so the monitor's
//             demand and the view's layout read one definition instead of two.
//  Notes:     ⚠️ `DashboardCard.demand` is half of the demand invariant (see MetricDemand.swift):
//             a card's set MUST cover every snapshot field the card renders, including the
//             verdicts it shows (throttling reads temperature and thermal pressure; the AI cards'
//             engine labels read GPU, ANE, power and bandwidth). A group missing here is shown
//             carried forward — a stale number that looks live.
//             The hidden set is stored under `DashboardCardVisibility.key` as a comma-separated
//             list of raw values. Unknown names are ignored on read (a card renamed or removed in a
//             later build must not throw away the rest of the list), and a hidden set is stored
//             rather than a shown one, so a card added later appears by default.
//
import Foundation

/// One card on the This Mac / remote dashboard.
public enum DashboardCard: String, CaseIterable, Sendable {
    case aiWorkload, aiRuntime, cpu, accelerators, memoryBandwidth, networkDisk, sensors, processes

    /// The card's title, as its header shows it.
    public var title: String {
        switch self {
        case .aiWorkload:      return "AI Workload"
        case .aiRuntime:       return "AI Runtime"
        case .cpu:             return "CPU"
        case .accelerators:    return "GPU / Media / Neural Engine"
        case .memoryBandwidth: return "Memory & Bandwidth"
        case .networkDisk:     return "Network & Disk"
        case .sensors:         return "Sensors"
        case .processes:       return "Processes"
        }
    }

    /// Every group this card reads, directly or through a verdict it displays.
    public var demand: MetricGroup {
        switch self {
        // Engine rows and the bottleneck verdict (gpu, bandwidth, memory pressure), the latched
        // activity (cpu, gpu, ane, power, bandwidth), both throttle verdicts (die and GPU
        // temperature, thermal pressure, GPU watts), memory risk, and the top AI processes.
        case .aiWorkload:
            return [.cpu, .gpu, .ane, .power, .bandwidth, .memory, .thermal, .temperature, .processes]
        // Runtime detection rides with the process table; the memory budget with memory. The
        // engine label and the CPU-offload hint read GPU, ANE, power and bandwidth.
        case .aiRuntime:
            return [.processes, .memory, .gpu, .ane, .power, .bandwidth]
        // The P-ceiling line appears on a throttle verdict, which needs die heat and pressure.
        case .cpu:
            return [.cpu, .temperature, .thermal]
        // GPU, media bandwidth, ANE activity and watts, plus the GPU throttle border.
        case .accelerators:
            return [.gpu, .bandwidth, .ane, .power, .temperature, .thermal]
        case .memoryBandwidth:
            return [.memory, .bandwidth]
        case .networkDisk:
            return [.network, .disk]
        case .sensors:
            return [.temperature, .thermal]
        case .processes:
            return .processes
        }
    }
}

/// Which dashboard cards are shown, and what the dashboard needs measured as a result.
public struct DashboardCardVisibility: Equatable, Sendable {
    /// UserDefaults key holding the hidden cards (comma-separated raw values).
    public static let key = "dashboard.hiddenCards"

    /// The header (SoC watts, battery) is always on screen.
    public static let headerDemand: MetricGroup = [.power, .battery]

    public private(set) var hidden: Set<DashboardCard>

    public init(hidden: Set<DashboardCard> = []) { self.hidden = hidden }

    /// Reads the stored form. Names this build does not know are skipped, not fatal.
    public init(storage: String) {
        hidden = Set(storage.split(separator: ",").compactMap {
            DashboardCard(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    /// The stored form, in card order so the same set always writes the same string.
    public var storage: String {
        DashboardCard.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    public func isShown(_ card: DashboardCard) -> Bool { !hidden.contains(card) }

    public mutating func set(_ card: DashboardCard, shown: Bool) {
        if shown { hidden.remove(card) } else { hidden.insert(card) }
    }

    /// Shows or hides one card in the stored set, leaving the rest as they are.
    public static func setShown(_ card: DashboardCard, _ shown: Bool, in defaults: UserDefaults) {
        var v = DashboardCardVisibility(storage: defaults.string(forKey: key) ?? "")
        v.set(card, shown: shown)
        defaults.set(v.storage, forKey: key)
    }

    /// True when every card is hidden and the dashboard is down to its header.
    public var allHidden: Bool { hidden.count == DashboardCard.allCases.count }

    /// What the dashboard reads with this visibility: the header, the warning banner when it is
    /// on (its verdicts are the alert path's), and every shown card.
    public func demand(warningBanner: Bool) -> MetricGroup {
        var d = Self.headerDemand
        if warningBanner { d.formUnion(.alerts) }
        for card in DashboardCard.allCases where isShown(card) { d.formUnion(card.demand) }
        return d
    }
}
