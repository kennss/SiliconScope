//
//  File:      PowerSample.swift
//  Created:   2026-06-08
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one power reading (Watts) for the Apple Silicon
//             SoC domains that SiliconScope surfaces.
//  Notes:     eCPUWatts/pCPUWatts split efficiency vs performance clusters.
//             socWatts is a derived sum (true system total needs a HID sensor,
//             added later). aneWatts is a power-based estimate (Apple exposes no
//             true ANE utilization).
//
import Foundation

public struct PowerSample: Sendable, Equatable, Codable {
    public var eCPUWatts: Double = 0   // efficiency cluster(s)
    public var pCPUWatts: Double = 0   // performance cluster(s)
    public var cpuWatts: Double = 0    // total CPU package (E + P + fabric)
    public var gpuWatts: Double = 0
    public var aneWatts: Double = 0    // Neural Engine (estimate)
    public var dramWatts: Double = 0
    /// Direct system/SoC total power when a sensor provides it (SMC `PSTR` on the A18/MacBook
    /// Neo, where IOReport's Energy Model only populates GPU). nil → fall back to the component sum.
    public var measuredSocWatts: Double? = nil
    /// How the per-domain rails (CPU, E/P, GPU, ANE, DRAM) were measured:
    ///   nil  — live: fresh on every read, averaged over the sampling slice (macOS ≤ 26)
    ///   > 0  — the counters update in steps rather than on every read (macOS 27, #65); every
    ///          domain wattage is the true average over this many seconds between two updates —
    ///          ~10 s on an M5 (batched), ~30 min on an M1 Max (refreshed by powerlog)
    ///   0    — they refresh slowly and no complete window has been seen yet: the domain wattages
    ///          are UNKNOWN and the zeros in them must not be shown as readings
    /// Optional so that a recording made before this existed decodes as live, which is what its
    /// numbers were.
    public var railWindowSeconds: Double? = nil
    /// The basis of `gpuWatts` when the GPU is read on its own, faster clock — same encoding as
    /// `railWindowSeconds`. On macOS 27 the "GPU Energy" channel (nJ) keeps moving while every other
    /// rail is slow; verified against GPU0 + GPU SRAM0 over four refresh windows on an M1 Max
    /// (0.271 vs 0.266, 0.315 vs 0.325, 0.262 vs 0.254, 0.269 vs 0.269 W). nil → the GPU shares the
    /// rails' basis, which is always the case where the rails are live.
    public var gpuWindowSeconds: Double? = nil
    /// The GPU's share over the RAILS' window, set when `gpuWatts` is on a faster clock. The SoC
    /// total uses it so that every term it adds covers the same span — a live GPU figure plus a
    /// half-hour CPU average is a number that describes no moment at all.
    public var railsGPUWatts: Double? = nil
    /// The WHOLE Mac's power draw, from the SMC's `PSTR` — display, storage and everything else
    /// included, so never to be shown as the SoC. Read only where the SoC rails are not live
    /// (macOS 27, #65): there it is the one live whole-machine figure left — measured every second
    /// on an M1 Max under 27.0 (22–46 W across a working day) while the SoC total was unknown.
    /// nil where the rails are live, or on a Mac without the key.
    public var systemWatts: Double? = nil

    public init() {}

    /// The rails are measured on the present: live, or over a span short enough to present as live.
    public var railsLive: Bool { railsKnown && !railsAveraged }

    /// `gpuWatts` is a reading, not a placeholder.
    public var gpuKnown: Bool { (gpuWindowSeconds ?? railWindowSeconds).map { $0 > 0 } ?? true }
    /// `gpuWatts` is an average over a span a reader should be told about.
    public var gpuAveraged: Bool { ((gpuWindowSeconds ?? railWindowSeconds) ?? 0) > Self.liveWindowLimit }
    /// `gpuWatts` describes the present.
    public var gpuLive: Bool { gpuKnown && !gpuAveraged }

    /// The domain wattages are readings (live or averaged), not placeholders.
    public var railsKnown: Bool { railWindowSeconds.map { $0 > 0 } ?? true }
    /// The domain wattages are an average over a span long enough that a reader should be told.
    public var railsAveraged: Bool { (railWindowSeconds ?? 0) > Self.liveWindowLimit }

    /// Spans up to this long are presented as live. An M5 on macOS 27 updates its counters in
    /// ~2.1 s batches and is read over ~10 s (EnergyRefreshTracker.batchSpan): recent enough to be
    /// the current figure, and marking every one of those ticks "averaged" would bury the one case
    /// that deserves the mark — the M1-class machines whose figure spans half an hour.
    public static let liveWindowLimit: Double = 15

    /// Direct system-power sensor when available (A18 SMC PSTR), else the derived component sum.
    ///
    /// ⚠️ The total is a RAILS quantity: every term covers the rails' span. When the GPU runs on its
    /// own clock its share comes from `railsGPUWatts`, and while the rails are unknown there is no
    /// share to add — falling back to the live GPU figure made an unknown total read as the GPU's
    /// wattage (seen on the wire as socWatts = gpuWatts with the rails still pending).
    public var socWatts: Double {
        measuredSocWatts ?? (cpuWatts + (railsGPUWatts ?? (gpuWindowSeconds == nil ? gpuWatts : 0)) + aneWatts + dramWatts)
    }
}
