//
//  File:      PowerSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one power reading (Watts) for the Apple Silicon
//             SoC domains that SiliconScope surfaces.
//  Notes:     eCPUWatts/pCPUWatts split efficiency vs performance clusters.
//             socWatts is a derived sum (true system total needs a HID sensor,
//             added later). aneWatts is a power-based estimate (Apple exposes no
//             true ANE utilization).
//
import Foundation

public struct PowerSample: Sendable, Equatable {
    public var eCPUWatts: Double = 0   // efficiency cluster(s)
    public var pCPUWatts: Double = 0   // performance cluster(s)
    public var cpuWatts: Double = 0    // total CPU package (E + P + fabric)
    public var gpuWatts: Double = 0
    public var aneWatts: Double = 0    // Neural Engine (estimate)
    public var dramWatts: Double = 0
    /// Direct system/SoC total power when a sensor provides it (SMC `PSTR` on the A18/MacBook
    /// Neo, where IOReport's Energy Model only populates GPU). nil → fall back to the component sum.
    public var measuredSocWatts: Double? = nil

    public init() {}

    /// Direct system-power sensor when available (A18 SMC PSTR), else the derived component sum.
    public var socWatts: Double { measuredSocWatts ?? (cpuWatts + gpuWatts + aneWatts + dramWatts) }
}
