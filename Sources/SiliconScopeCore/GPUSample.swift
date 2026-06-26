//
//  File:      GPUSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one GPU reading: utilization, average clock, and the GPU's
//             unified-memory footprint.
//  Notes:     usage is 0...1 (active residency fraction); freq is the residency-weighted
//             average clock in MHz. Power lives in PowerSample. Memory comes from
//             IOAccelerator "PerformanceStatistics": inUse = actively used by the GPU now;
//             allocated = the reserved GPU pool (can be large — not all touched).
//
import Foundation

public struct GPUSample: Sendable, Equatable, Codable {
    public var usage: Double = 0       // 0...1
    public var freqMHz: Double = 0
    public var inUseMemoryBytes: UInt64 = 0
    public var allocatedMemoryBytes: UInt64 = 0

    public init() {}

    public var usagePercent: Double { usage * 100 }
    public var inUseMemoryGB: Double { Double(inUseMemoryBytes) / 1_073_741_824 }
    public var allocatedMemoryGB: Double { Double(allocatedMemoryBytes) / 1_073_741_824 }

    /// GPU in-use memory as a fraction (0...1) of total unified memory — lets the dashboard
    /// render it as a bar on the same scale as the other accelerator meters.
    public var inUseMemoryFraction: Double {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(1, Double(inUseMemoryBytes) / total) : 0
    }
}
