//
//  File:      FleetReadout.swift
//  Created:   2026-10-18
//  Updated:   2026-10-19
//  Developer: SiliconScope contributors
//  Overview:  How a remote machine's GPU watts and temperature are worded in the Fleet views, so a
//             value the machine could not measure is left out instead of printed as 0.
//  Notes:     Pure functions, no SwiftUI. The wire format is unchanged: a Mac still sends 0 for an
//             unknown value, and `FleetApple` is what tells that apart from a real reading.
//
import Foundation

/// Wording for readings a Fleet tile or row can't always vouch for.
public enum FleetReadout {
    /// A GPU's watts as "12W", or nil when they are unknown.
    /// - Apple (`apple` present): unknown while the macOS 27 energy window is pending
    ///   (`PowerSample.gpuKnown`) — the wire carries 0 then, which must not read as a reading.
    ///   A span longer than a tick is prefixed "~", as everywhere else.
    /// - NVIDIA/Linux: shown as sent. The Go agent turns an unsupported `nvidia-smi` value into 0
    ///   (atof, agent/collect/collector.go) and the wire has no validity flag, so unknown can't be
    ///   told from a true 0 W there.
    public static func gpuWatts(_ g: FleetGPU, apple: FleetApple?) -> String? {
        guard let apple else { return "\(Int(g.powerDrawW))W" }
        let p = apple.powerSample
        guard p.gpuKnown else { return nil }
        return (p.gpuAveraged ? "~" : "") + "\(Int(g.powerDrawW))W"
    }

    /// A GPU's temperature as "45°C", or nil. The Mac encoder sends 0 for "no GPU sensor"
    /// (`TemperatureSample.hasGPU`), so on Apple 0 means absent; elsewhere shown as sent (see above).
    public static func gpuTemperature(_ g: FleetGPU, apple: FleetApple?) -> String? {
        if apple != nil && g.temperatureC <= 0 { return nil }
        return "\(Int(g.temperatureC))°C"
    }
}
