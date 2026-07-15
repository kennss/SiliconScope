//
//  File:      BandwidthSample.swift
//  Created:   2026-06-08
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one unified-memory bandwidth reading (GB/s), split
//             by requestor. The headline signal for local-LLM throughput (token
//             generation is memory-bandwidth bound on Apple Silicon).
//  Notes:     cpuGBs = ECPU + PCPU* DCS traffic, gpuGBs = GFX, otherGBs = display /
//             media / IO / storage. Sum of read + write. `isEstimated` flags readings
//             from BandwidthSampler's PMP-histogram fallback path (see its file header).
//
import Foundation

public struct BandwidthSample: Sendable, Equatable, Codable {
    public var cpuGBs: Double = 0
    public var gpuGBs: Double = 0
    public var mediaGBs: Double = 0    // Media Engine: video codec / ProRes traffic
    public var otherGBs: Double = 0    // display, storage, ISP, PCIe, ...
    /// Measured total when the per-requestor split isn't available (A18/MacBook Neo: IOReport
    /// exposes only PMP "DRAM BW" by frequency state, not by requestor). nil → fall back to the sum.
    public var measuredTotalGBs: Double? = nil

    /// True when this sample came from `BandwidthSampler`'s PMP "DCS BW" residency-histogram
    /// fallback (used when the classic "AMC Stats" byte-delta subscription is unavailable — see
    /// BandwidthSampler's file header and github.com/kennss/SiliconScope#14/#29). That path's
    /// per-requestor values are clamped at a labeled "32GB/s" top bucket and `totalGBs` is a sum
    /// across many requestor channels rather than one authoritative chip-wide counter, so figures
    /// can understate true peak bandwidth and should not be compared precisely against a chip's
    /// spec ceiling. UI that reasons about "% of ceiling" should treat this as an honest estimate,
    /// not a measurement — same "label the estimate" philosophy as the ANE usage number.
    public var isEstimated: Bool = false

    public init() {}

    public var totalGBs: Double { measuredTotalGBs ?? (cpuGBs + gpuGBs + mediaGBs + otherGBs) }
}
