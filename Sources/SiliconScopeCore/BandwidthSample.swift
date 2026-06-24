//
//  File:      BandwidthSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one unified-memory bandwidth reading (GB/s), split
//             by requestor. The headline signal for local-LLM throughput (token
//             generation is memory-bandwidth bound on Apple Silicon).
//  Notes:     cpuGBs = ECPU + PCPU* DCS traffic, gpuGBs = GFX, otherGBs = display /
//             media / IO / storage. Sum of read + write.
//
import Foundation

public struct BandwidthSample: Sendable, Equatable {
    public var cpuGBs: Double = 0
    public var gpuGBs: Double = 0
    public var mediaGBs: Double = 0    // Media Engine: video codec / ProRes traffic
    public var otherGBs: Double = 0    // display, storage, ISP, PCIe, ...
    /// Measured total when the per-requestor split isn't available (A18/MacBook Neo: IOReport
    /// exposes only PMP "DRAM BW" by frequency state, not by requestor). nil → fall back to the sum.
    public var measuredTotalGBs: Double? = nil

    public init() {}

    public var totalGBs: Double { measuredTotalGBs ?? (cpuGBs + gpuGBs + mediaGBs + otherGBs) }
}
