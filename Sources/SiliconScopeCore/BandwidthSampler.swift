//
//  File:      BandwidthSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads unified-memory bandwidth (GB/s) sudolessly. Three read strategies,
//             tried in order at init and locked in for the sampler's lifetime:
//             (1) A18: IOReport "PMP" group, "DRAM BW" subgroup, Simple format byte deltas
//                 by DVFS frequency state (no per-requestor split).
//             (2) M-series, classic: IOReport "AMC Stats" group, "Perf Counters" subgroup,
//                 Simple format "<unit> DCS RD/WR" byte-delta channels, per requestor.
//             (3) M-series, PMP histogram fallback: on chip/OS combinations where the
//                 "AMC Stats" subscription itself fails outright (confirmed on an Apple M4
//                 Max, macOS 26.5.2 — IOReportCopyChannelsInGroup finds ~190 channels but
//                 IOReportCreateSubscription returns nil for the group), the same
//                 per-requestor byte counters live instead under IOReport "PMP", subgroup
//                 "DCS BW", as State-format residency histograms named "1GB/s".."32GB/s"
//                 per requestor (e.g. "EACC0 RD+WR", "AGX RD+WR") — the same
//                 residency-weighting idiom CPUSampler already uses for DVFS frequency,
//                 applied to bandwidth buckets instead of MHz.
//  Notes:     Requestor map (classic path): ECPU/PCPU* -> CPU, GFX -> GPU,
//             ISP/VENC/VDEC/PRORES/CODEC/JPEG -> Media, "DCS" is the chip-wide aggregate
//             (= total); other = total - the above. MSR is intentionally NOT media (matches
//             NeoAsitop). Requestor list adapted from NeoAsitop (op06072/NeoAsitop), MIT
//             License. `classify(requestor:)` additionally tolerates a leading chip-id/
//             core-id token (e.g. "DIE0 ECPU0") on top of the bare unit name, per
//             github.com/kennss/SiliconScope#14 (Apple restructured "AMC Stats" channel
//             names on macOS 27 beta / M3 Max to add this prefix and split RD/WR channels).
//             The PMP-histogram fallback path (3) has no authoritative chip-wide total
//             channel, so `totalGBs` there is the sum of the classified buckets (see
//             `BandwidthSample.totalGBs`); its top bucket ("32GB/s") is very likely a
//             saturating/clamped bin, not a literal ceiling — observed residency spikes
//             there under heavy GPU load — so the weighted average is a real, directionally
//             correct GB/s figure but can understate true peak bandwidth. Honest limitation,
//             not hidden: same "label the estimate" philosophy as the ANE usage number.
//             `channelDump()` (raw inventory dump, both paths) exists to diagnose chip/OS
//             combinations neither path handles yet.
//
import Foundation
import CIOReport

public final class BandwidthSampler {
    private enum Mode {
        case a18Simple          // PMP / "DRAM BW", Simple format
        case amcStatsSimple     // AMC Stats / "Perf Counters", Simple format
        case pmpHistogram       // PMP / "DCS BW", State format residency histogram
    }

    private let mode: Mode
    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary
    // A18 (MacBook Neo) has no per-requestor "AMC Stats"; its DRAM bandwidth lives in the "PMP"
    // group's "DRAM BW" subgroup (by DVFS frequency state). M-series normally uses "AMC Stats".
    private let isA18 = SensorCatalog.detectGeneration() == .a18

    public init?() {
        if isA18 {
            guard let channels = IOReportCopyChannelsInGroup("PMP" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
                  let (sub, subscribed) = Self.subscribe(to: channels)
            else { return nil }
            mode = .a18Simple
            subscription = sub
            subscribedChannels = subscribed
            return
        }

        // Try the classic per-requestor "AMC Stats" path first — still the primary, richer
        // source (CPU/GPU/Media split) where it works.
        if let channels = IOReportCopyChannelsInGroup("AMC Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
           let (sub, subscribed) = Self.subscribe(to: channels) {
            mode = .amcStatsSimple
            subscription = sub
            subscribedChannels = subscribed
            return
        }

        // Classic path unavailable (verified failure mode: IOReportCopyChannelsInGroup finds
        // channels but IOReportCreateSubscription itself returns nil for "AMC Stats" — not a
        // naming/classification issue, the group is simply not subscribable). Fall back to the
        // PMP "DCS BW" histogram, which carries the same per-requestor byte-traffic information
        // in a different (State/residency) shape.
        if let channels = IOReportCopyChannelsInGroup("PMP" as CFString, "DCS BW" as CFString, 0, 0, 0)?.takeRetainedValue(),
           let (sub, subscribed) = Self.subscribe(to: channels) {
            mode = .pmpHistogram
            subscription = sub
            subscribedChannels = subscribed
            return
        }

        return nil
    }

    private static func subscribe(to channels: CFMutableDictionary) -> (IOReportSubscriptionRef, CFMutableDictionary)? {
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, channels, &subbed, 0, nil),
              let subscribed = subbed?.takeRetainedValue()
        else { return nil }
        return (sub, subscribed)
    }

    public func sample(interval: TimeInterval = 0.2) -> BandwidthSample {
        let first = IOReportCreateSamples(subscription, subscribedChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(subscription, subscribedChannels, nil)

        guard let a = first?.takeRetainedValue(),
              let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            return BandwidthSample()
        }

        switch mode {
        case .a18Simple:      return Self.sampleA18Simple(delta: delta, interval: interval)
        case .amcStatsSimple: return Self.sampleAMCStatsSimple(delta: delta, interval: interval)
        case .pmpHistogram:   return Self.samplePMPHistogram(delta: delta)
        }
    }

    // MARK: - A18: PMP "DRAM BW" frequency-state lanes (Simple format, bytes)

    /// Sum the PMP "DRAM BW" frequency-state lanes (F1–F5 RD/WR, bytes) for the total.
    /// There's no per-requestor split on A18, so only the total is known (cpu/gpu/media stay 0).
    private static func sampleA18Simple(delta: CFDictionary, interval: TimeInterval) -> BandwidthSample {
        let seconds = max(interval, 0.001)
        var totalBytes = 0.0
        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatSimple,
                  let subgroupRef = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue(),
                  (subgroupRef as String) == "DRAM BW",
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else { return Int32(kKtopIOReportIterOk) }
            let name = (nameRef as String).uppercased()
            guard name.hasSuffix(" RD") || name.hasSuffix(" WR") else { return Int32(kKtopIOReportIterOk) }
            totalBytes += Double(IOReportSimpleGetIntegerValue(channel, 0))
            return Int32(kKtopIOReportIterOk)
        }
        var result = BandwidthSample()
        result.measuredTotalGBs = (totalBytes / seconds) / 1_000_000_000.0
        return result
    }

    // MARK: - Classic M-series: "AMC Stats" / "Perf Counters" (Simple format, bytes)

    private static func sampleAMCStatsSimple(delta: CFDictionary, interval: TimeInterval) -> BandwidthSample {
        let seconds = max(interval, 0.001)
        var cpu = 0.0, gpu = 0.0, media = 0.0, total = 0.0

        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatSimple,
                  let subgroupRef = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue(),
                  (subgroupRef as String) == "Perf Counters",
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }

            let name = (nameRef as String).uppercased()
            // Only DCS read/write byte counters (skip CAS/RAS/cycle/entry counters). Tolerates
            // the combined "RD/WR", split "RD"/"WR", and the "RD/WR/RDWR" / "RD/WR + RD/WR"
            // shapes observed on macOS 27 (github.com/kennss/SiliconScope#14) as well as the
            // original clean " RD"/" WR" suffix.
            guard Self.hasReadWriteToken(name), name.contains("DCS") else {
                return Int32(kKtopIOReportIterOk)
            }
            let requestor = Self.stripReadWriteSuffix(name)
            let gbs = (Double(IOReportSimpleGetIntegerValue(channel, 0)) / seconds) / 1_000_000_000.0

            switch Self.classify(requestor: requestor) {
            case .total: total += gbs    // "DCS" chip-wide aggregate = true total
            case .cpu:   cpu += gbs
            case .gpu:   gpu += gbs
            case .media: media += gbs
            case .other: break           // MSR / DISP / ANS / PCIe … folded into "other" below
            }
            return Int32(kKtopIOReportIterOk)
        }

        var result = BandwidthSample()
        result.cpuGBs = cpu
        result.gpuGBs = gpu
        result.mediaGBs = media
        // "DCS" is the authoritative chip total; derive other so the parts sum to it.
        result.otherGBs = total > 0 ? max(0, total - cpu - gpu - media) : 0
        return result
    }

    /// True if an (uppercased) channel name ends in a trailing token built from `RD`/`WR`
    /// markers, in any of the shapes observed across macOS 26/27: a single `RD` or `WR`,
    /// combined `RD/WR`, `RD/WR/RDWR`, or an appended `RD/WR + RD/WR`. Excludes structural,
    /// non-byte-counter channels by construction (they carry no RD/WR token at all).
    static func hasReadWriteToken(_ name: String) -> Bool {
        Self.readWriteSuffixes.contains { name.hasSuffix($0) }
    }

    /// Recognized trailing RD/WR token shapes, longest/most-specific first — shared by
    /// `hasReadWriteToken` (the guard) and `stripReadWriteSuffix` (the recovery), so the two stay
    /// in lockstep by construction.
    private static let readWriteSuffixes = [
        " RD/WR + RD/WR", " RD/WR/RDWR", " RD/WR", " RD", " WR",
    ]

    /// Strips the trailing RD/WR token (in whichever shape `hasReadWriteToken` matched) to
    /// recover the requestor-plus-DCS prefix, e.g. "DIE0 ECPU0 DCS RD/WR + RD/WR" -> "DIE0
    /// ECPU0 DCS". The recovered string still carries any chip-id prefix (e.g. "DIE0"); it is
    /// `classify(requestor:)`'s job, not this function's, to see past that.
    static func stripReadWriteSuffix(_ name: String) -> String {
        for suffix in Self.readWriteSuffixes {
            if name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return name
    }

    // MARK: - PMP histogram fallback: "PMP" / "DCS BW" (State format, residency histogram)

    /// Residency-weighted average GB/s from a bandwidth-histogram channel's (bucket GB/s,
    /// residency) pairs — the same residency-weighting idiom `CPUSampler` uses for DVFS
    /// frequency (`docs/ioreport-channels.md`: "active-state residency × DVFS MHz, weighted =
    /// average frequency"), applied here to bandwidth buckets instead of MHz.
    static func weightedAverageGBs(_ buckets: [(gbs: Double, residency: UInt64)]) -> Double {
        let totalResidency = buckets.reduce(0.0) { $0 + Double($1.residency) }
        guard totalResidency > 0 else { return 0 }
        let weighted = buckets.reduce(0.0) { $0 + Double($1.residency) * $1.gbs }
        return weighted / totalResidency
    }

    /// Parses an IOReport bandwidth-histogram state name like "   1GB/s" (whitespace-padded)
    /// into its GB/s value. Returns nil for anything that doesn't match "<number>GB/s".
    static func parseHistogramBucketGBs(_ stateName: String) -> Double? {
        let trimmed = stateName.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        guard upper.hasSuffix("GB/S") else { return nil }
        let numberPart = trimmed.dropLast(4).trimmingCharacters(in: .whitespaces)
        return Double(numberPart)
    }

    /// Which bandwidth bucket a PMP-histogram requestor name (e.g. "EACC0", "AGX", "JPEG0")
    /// belongs to — the naming convention used by the "DCS BW"/"AF BW" PMP subgroups, distinct
    /// from the classic "AMC Stats" `classify(requestor:)` map (different requestor spellings:
    /// "EACC*"/"PACC*" for CPU clusters rather than "ECPU"/"PCPU", "AGX" for GPU rather than
    /// "GFX"). There is no PMP-histogram equivalent of the classic path's chip-wide "DCS"
    /// aggregate, so this never returns `.total`.
    static func classifyPMPHistogramRequestor(_ name: String) -> Requestor {
        let upper = name.uppercased()
        if upper.hasPrefix("EACC") || upper.hasPrefix("PACC") { return .cpu }
        if upper.hasPrefix("AGX") { return .gpu }
        if upper.hasPrefix("ISP") || upper.hasPrefix("JPEG") || upper.hasPrefix("PRORES")
            || upper.hasPrefix("SCODEC") || upper.hasPrefix("AVE") || upper.hasPrefix("AVD") {
            return .media
        }
        return .other   // ANE0, ANS, ATC0-3, DISPEXT0-3, DISPINT, MSR0/1, AMCC, …
    }

    private static func samplePMPHistogram(delta: CFDictionary) -> BandwidthSample {
        var cpu = 0.0, gpu = 0.0, media = 0.0, other = 0.0

        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatState,
                  let subgroupRef = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue(),
                  (subgroupRef as String) == "DCS BW",
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }
            let name = nameRef as String
            // Only the combined read+write channel per requestor — the separate RD-only/WR-only
            // breakdown channels would double-count if also summed in.
            guard name.uppercased().hasSuffix(" RD+WR") else { return Int32(kKtopIOReportIterOk) }
            let requestor = String(name.dropLast(6))   // strip " RD+WR"

            let stateCount = Int(IOReportStateGetCount(channel))
            var buckets: [(gbs: Double, residency: UInt64)] = []
            buckets.reserveCapacity(stateCount)
            for i in 0..<stateCount {
                let stateName = (IOReportStateGetNameForIndex(channel, Int32(i))?
                    .takeUnretainedValue() as String?) ?? ""
                guard let gbs = Self.parseHistogramBucketGBs(stateName) else { continue }
                buckets.append((gbs, IOReportStateGetResidency(channel, Int32(i))))
            }
            let value = Self.weightedAverageGBs(buckets)

            switch Self.classifyPMPHistogramRequestor(requestor) {
            case .cpu:            cpu += value
            case .gpu:            gpu += value
            case .media:          media += value
            case .other, .total:  other += value
            }
            return Int32(kKtopIOReportIterOk)
        }

        var result = BandwidthSample()
        result.cpuGBs = cpu
        result.gpuGBs = gpu
        result.mediaGBs = media
        result.otherGBs = other
        // No authoritative chip-wide total in this path — BandwidthSample.totalGBs falls back
        // to summing cpu+gpu+media+other, which is exactly what we want here.
        return result
    }

    // MARK: - Diagnostics

    /// Diagnostic dump of the raw bandwidth-channel inventory for the relevant IOReport
    /// group(s) on this machine — independent of whether `sample()` currently classifies any of
    /// it correctly. Tries the classic "AMC Stats" (or A18 "PMP") path first, matching what
    /// `sample()` itself would use; if that subscription is unavailable, falls back to dumping
    /// the "PMP" / "DCS BW" histogram (state name + residency per requestor) so contributors get
    /// full diagnostic material regardless of which mechanism their machine actually has.
    /// Motivating case: a chip/OS combination restructures or relocates the channel layout in a
    /// way `sample()` doesn't handle (see github.com/kennss/SiliconScope#14 — `DIE0`-prefixed
    /// per-core names, split RD/WR channels — and this project's own M4 Max/macOS 26.5.2 finding
    /// that "AMC Stats" subscription can fail outright, with the same data relocated to PMP/"DCS
    /// BW" as a State-format histogram). Surfaced by `sscope-cli --bandwidth`.
    public static func channelDump(interval: TimeInterval = 0.2) -> [String] {
        let isA18 = SensorCatalog.detectGeneration() == .a18
        let groupName = isA18 ? "PMP" : "AMC Stats"

        if let all = IOReportCopyChannelsInGroup(groupName as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
           let (sub, channels) = subscribe(to: all) {
            let first = IOReportCreateSamples(sub, channels, nil)
            Thread.sleep(forTimeInterval: interval)
            let second = IOReportCreateSamples(sub, channels, nil)
            guard let a = first?.takeRetainedValue(), let b = second?.takeRetainedValue(),
                  let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
            else {
                return ["IOReport sampling failed for group \"\(groupName)\""]
            }
            let seconds = max(interval, 0.001)
            var lines: [String] = []
            IOReportIterate(delta) { channel in
                guard let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() else {
                    return Int32(kKtopIOReportIterOk)
                }
                let name = nameRef as String
                let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                let sg = subgroup.isEmpty ? "" : " (\(subgroup))"
                let format = IOReportChannelGetFormat(channel)
                guard format == kKtopIOReportFormatSimple else {
                    lines.append("[\(groupName)]\(sg) \(name) [fmt \(format)] = (non-Simple, not read)")
                    return Int32(kKtopIOReportIterOk)
                }
                let raw = IOReportSimpleGetIntegerValue(channel, 0)
                if raw == Int.min {
                    lines.append("[\(groupName)]\(sg) \(name) [Simple] = — (not populated, raw INT64_MIN)")
                } else {
                    let gbs = (Double(raw) / seconds) / 1_000_000_000.0
                    lines.append("[\(groupName)]\(sg) \(name) [Simple] = \(String(format: "%.3f", gbs)) GB/s  (raw \(raw))")
                }
                return Int32(kKtopIOReportIterOk)
            }
            return ["=== \"\(groupName)\" subscription OK — \(lines.count) channels ==="] + lines.sorted()
        }

        // Classic path unavailable — fall back to the PMP "DCS BW" histogram (see samplePMPHistogram).
        var out = ["\"\(groupName)\" subscription unavailable — falling back to PMP \"DCS BW\" histogram dump:"]
        guard let pmp = IOReportCopyChannelsInGroup("PMP" as CFString, "DCS BW" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let (pmpSub, pmpChannels) = subscribe(to: pmp)
        else {
            out.append("PMP \"DCS BW\" subgroup also unavailable on this machine")
            return out
        }
        let first = IOReportCreateSamples(pmpSub, pmpChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(pmpSub, pmpChannels, nil)
        guard let a = first?.takeRetainedValue(), let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            out.append("PMP \"DCS BW\" sampling failed")
            return out
        }
        var lines: [String] = []
        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatState,
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else { return Int32(kKtopIOReportIterOk) }
            let name = nameRef as String
            guard name.uppercased().hasSuffix(" RD+WR") else { return Int32(kKtopIOReportIterOk) }
            let stateCount = Int(IOReportStateGetCount(channel))
            var buckets: [(gbs: Double, residency: UInt64)] = []
            var nonZero: [String] = []
            for i in 0..<stateCount {
                let stateName = (IOReportStateGetNameForIndex(channel, Int32(i))?
                    .takeUnretainedValue() as String?) ?? "?"
                let residency = IOReportStateGetResidency(channel, Int32(i))
                if let gbs = parseHistogramBucketGBs(stateName) { buckets.append((gbs, residency)) }
                if residency > 0 { nonZero.append("\(stateName.trimmingCharacters(in: .whitespaces))=\(residency)") }
            }
            let weighted = weightedAverageGBs(buckets)
            let bucket = String(name.dropLast(6))
            lines.append("PMP (DCS BW) \(bucket) -> \(String(format: "%.3f", weighted)) GB/s  (states: \(nonZero.joined(separator: ", ")))")
            return Int32(kKtopIOReportIterOk)
        }
        out.append("=== PMP \"DCS BW\" histogram — \(lines.count) requestors ===")
        out += lines.sorted()
        return out
    }

    /// Which bandwidth bucket a DCS requestor belongs to. Pure (string → unit), so the
    /// NeoAsitop-adapted requestor map can be unit-tested and locked against regressions.
    /// Tolerant of a leading chip-id/core-id prefix (e.g. "DIE0 ECPU0 DCS" alongside the
    /// original bare "ECPU DCS") — see github.com/kennss/SiliconScope#14.
    enum Requestor { case total, cpu, gpu, media, other }

    static func classify(requestor: String) -> Requestor {
        if requestor == "DCS" { return .total }
        if Self.contains(requestor, unitPrefix: "ECPU") || Self.contains(requestor, unitPrefix: "PCPU") {
            return .cpu
        }
        if Self.contains(requestor, unitPrefix: "GFX") { return .gpu }
        // Media Engine = isp + strm codec + prores + vdec + venc + jpeg + jpg. MSR is NOT media.
        if Self.contains(requestor, unitPrefix: "VENC") || Self.contains(requestor, unitPrefix: "VDEC")
            || Self.contains(requestor, unitPrefix: "ISP") || Self.contains(requestor, unitPrefix: "JPG")
            || Self.contains(requestor, unitPrefix: "JPEG") || requestor.contains("PRORES")
            || requestor.contains("CODEC") {
            return .media
        }
        return .other
    }

    /// True if `requestor` contains `unitPrefix` as a whole "word" — either at the very start
    /// (the original bare-name shape, e.g. "ECPU DCS") or immediately after a leading chip-id/
    /// core-id token separated by a space (e.g. "DIE0 ECPU0 DCS"). Per-core numeric suffixes on
    /// the unit itself (the "0"/"1" in "ECPU0") are tolerated by construction since this checks
    /// containment of the prefix, not an exact token match — so new core counts on future chips
    /// need no code change, matching this project's "variants need no special-casing" pattern
    /// for SMC sensor keys.
    private static func contains(_ requestor: String, unitPrefix: String) -> Bool {
        if requestor.hasPrefix(unitPrefix) { return true }
        return requestor.range(of: " " + unitPrefix) != nil
    }
}
