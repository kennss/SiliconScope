//
//  File:      BandwidthSample.swift
//  Created:   2026-06-08
//  Updated:   2026-11-20
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
//             `belowGBs` is the one reading that is NOT a number: a histogram that held all its
//             residency in its lowest band only says traffic was under that band (#93). Text
//             goes through `totalText`, charts leave it out, and `totalGBs` reads 0 for math.
//             `hasRequestorSplit` is false whenever only a total was read; the lanes are then
//             unknown, not zero.
//
import Foundation

public struct BandwidthSample: Sendable, Equatable, Codable {
    public var cpuGBs: Double = 0
    public var gpuGBs: Double = 0
    public var mediaGBs: Double = 0    // Media Engine: video codec / ProRes traffic
    /// Neural Engine traffic, split out of `otherGBs`. nil = not split: a recording or a remote
    /// agent from before it existed, whose ANE traffic is still inside `otherGBs`. A 0 there would
    /// claim an idle ANE that was never measured separately.
    public var aneGBs: Double? = nil
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

    /// Set when every bandwidth histogram this reading came from held all of its residency in
    /// its lowest band: the total is then only known to be under this value (GB/s), the sum of
    /// those lowest bands. `measuredTotalGBs` stays nil and the lanes 0, so `totalGBs` reads 0
    /// for arithmetic (fill fractions, peak, the bottleneck verdict) — a reading that low is
    /// never the limit. Anything shown as text must use `totalText`, and a chart must leave the
    /// sample out rather than draw a value that was never read. M3 Max's lowest band is 32 GB/s
    /// and each M3 Ultra die's is 64, so an idle Ultra reads "< 128 GB/s" (#93).
    public var belowGBs: Double? = nil

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
        aneGBs = try c.decodeIfPresent(Double.self, forKey: .aneGBs)
        otherGBs = try c.decodeIfPresent(Double.self, forKey: .otherGBs) ?? 0
        measuredTotalGBs = try c.decodeIfPresent(Double.self, forKey: .measuredTotalGBs)
        isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
        belowGBs = try c.decodeIfPresent(Double.self, forKey: .belowGBs)
    }

    public var totalGBs: Double { measuredTotalGBs ?? (cpuGBs + gpuGBs + mediaGBs + (aneGBs ?? 0) + otherGBs) }

    /// False when only a total was read: the aggregate histogram on M3 Max/Ultra (#46, #93), A18's
    /// "DRAM BW", or a floor bound. The per-requestor lanes (cpu, gpu, media, ane, other) are then
    /// not measurements — they hold their zero defaults — and must be shown as unknown ("—"), kept
    /// out of charts and averages, and never read as "this engine moved no memory". The Media
    /// Engine's activity comes from its lane, so on these chips it is unknown too.
    /// Derived from fields every recording and Fleet frame already carries, so old data reads right.
    public var hasRequestorSplit: Bool { measuredTotalGBs == nil && belowGBs == nil }

    /// One requestor lane as text, or "—" where this chip reads only a total (`hasRequestorSplit`).
    public func laneText(_ gbs: Double, decimals: Int = 0) -> String {
        hasRequestorSplit ? String(format: "%.\(decimals)f GB/s", gbs) : "—"
    }

    /// The Media Engine's traffic — its only activity reading — or "—" where it can't be split out.
    public var mediaText: String { laneText(mediaGBs, decimals: 1) }

    /// Why the lanes read "—", for a tooltip.
    public static let noSplitNote = "This chip reports only its total memory traffic. How that divides between CPU, GPU, media and other requestors can't be read, so those rows show — rather than 0."

    /// The total as text: "< 128 GB/s" when it was below the histogram's resolution.
    public var totalText: String { Self.totalText(totalGBs: totalGBs, belowGBs: belowGBs) }

    /// Shared with the Fleet wire type so a remote Mac reads the same way as this one.
    public static func totalText(totalGBs: Double, belowGBs: Double?) -> String {
        if let below = belowGBs { return String(format: "< %.0f GB/s", below) }
        return String(format: "%.0f GB/s", totalGBs)
    }
}
