//
//  File:      BandwidthSample.swift
//  Created:   2026-06-08
//  Updated:   2026-08-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one unified-memory bandwidth reading (GB/s), split
//             by requestor. The headline signal for local-LLM throughput (token
//             generation is memory-bandwidth bound on Apple Silicon).
//  Notes:     cpuGBs = ECPU + PCPU* DCS traffic, gpuGBs = GFX, otherGBs = display /
//             media / IO / storage. Sum of read + write. `isEstimated` flags readings
//             from BandwidthSampler's PMP-histogram fallback path (see its file header).
//             Decoding is hand-written (`init(from:)`) rather than synthesized so that
//             ADDITIVE fields stay backward-compatible per RecordingFormat.swift's policy:
//             the synthesized decoder requires every non-optional key, so a field added
//             later (e.g. `isEstimated`) would throw .keyNotFound on older .ssrec frames and
//             SessionReader would drop every frame → an old recording opens as `.noFrames`.
//             decodeIfPresent + the property default keeps pre-existing recordings loading.
//
import Foundation

public struct BandwidthSample: Sendable, Equatable, Codable {
    public var cpuGBs: Double = 0
    public var gpuGBs: Double = 0
    public var mediaGBs: Double = 0    // Media Engine: video codec / ProRes traffic
    public var otherGBs: Double = 0    // display, storage, ISP, PCIe, ...
    /// Measured total when the per-requestor split is unavailable (A18 "DRAM BW", or the sole
    /// PMP0/AMCC histogram on M3 Max/macOS 27). nil → fall back to the classified requestor sum.
    public var measuredTotalGBs: Double? = nil

    /// True when this sample came from `BandwidthSampler`'s PMP "DCS BW" residency-histogram
    /// fallback (used when the classic "AMC Stats" byte-delta subscription is unavailable — see
    /// BandwidthSampler's file header and github.com/kennss/SiliconScope#14/#29/#46). M4/M5
    /// expose per-requestor histograms whose labeled 32GB/s top bucket can clamp real traffic;
    /// M3 Max/macOS 27 exposes one wider AMCC aggregate histogram instead. Both are estimates,
    /// not precise byte-delta measurements, so UI that reasons about a chip's ceiling must say so.
    public var isEstimated: Bool = false

    public init() {}

    /// Hand-written decoder (see the file header): every key is optional-on-read so that any
    /// field added in a later version decodes to its default on frames that predate it, instead
    /// of throwing `.keyNotFound` and making SessionReader discard the whole recording. Encoding
    /// stays synthesized — new files always carry every key; only reads must tolerate absence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuGBs = try c.decodeIfPresent(Double.self, forKey: .cpuGBs) ?? 0
        gpuGBs = try c.decodeIfPresent(Double.self, forKey: .gpuGBs) ?? 0
        mediaGBs = try c.decodeIfPresent(Double.self, forKey: .mediaGBs) ?? 0
        otherGBs = try c.decodeIfPresent(Double.self, forKey: .otherGBs) ?? 0
        measuredTotalGBs = try c.decodeIfPresent(Double.self, forKey: .measuredTotalGBs)
        isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

    public var totalGBs: Double { measuredTotalGBs ?? (cpuGBs + gpuGBs + mediaGBs + otherGBs) }
}
