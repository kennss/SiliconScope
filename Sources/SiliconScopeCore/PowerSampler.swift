//
//  File:      PowerSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads per-domain SoC power (CPU E/P, GPU, ANE, DRAM) sudolessly via
//             the private IOReport framework. Subscribes once, then each sample()
//             takes two snapshots `interval` apart and converts the delta to Watts.
//  Notes:     No single group is a precondition — see init?(). Group and channel names go
//             through IOReportNaming so a die/chip-id token ("DIE0 GPU0") still resolves (#35).
//             Energy unit is millijoules: Watts = (mJ delta / seconds) / 1000.
//             M1 Pro/Max/M2+: everything is in the "Energy Model" group — CPU Energy = total CPU,
//             EACC*_CPU = E clusters, PACC*_CPU = P clusters, GPU0/GPU SRAM0 = GPU, ANE0/ANE1 =
//             Neural Engine, DRAM0 = memory ("GPU Energy" excluded — different unit ~nJ).
//             Base M1 (MacBook Air) exposes NO ANE in "Energy Model": its ANE/GPU/DRAM/E-P rails
//             live in the "PMP" group, "Energy Counters" subgroup (same mJ unit, verified via
//             --power-debug: ANE=3.4W under load). sample() falls back to PMP when Energy Model
//             has no ANE channel. Only Simple-format channels hold energy.
//
import Foundation
import CIOReport

public final class PowerSampler {
    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary
    // A18 (MacBook Neo): IOReport's Energy Model only populates GPU, so the component sum is ~0.
    // SMC `PSTR` gives the true system/SoC total (direct watts). Read it when on an A18.
    private let smc = SMCReader()
    private let isA18 = SensorCatalog.detectGeneration() == .a18

    /// Returns nil only when NO energy channels can be subscribed at all (e.g. non-Apple-Silicon).
    ///
    /// ⚠️ "Energy Model" is a source, NOT a precondition. It used to be a hard `guard`, which made
    /// the whole sampler fail to construct when that one group was absent — and because the PMP
    /// merge sat *after* the guard, the base-M1 fallback was unreachable in exactly the case it
    /// exists for. Every wattage then read 0.0 while temperature, bandwidth and GPU usage kept
    /// working, since those samplers subscribe to other groups (#35). Each source is now merged
    /// independently and construction succeeds if any one of them yields channels.
    public init?() {
        var merged: CFMutableDictionary?
        func merge(_ next: CFMutableDictionary?) {
            guard let next else { return }
            if let existing = merged { IOReportMergeChannels(existing, next, nil) } else { merged = next }
        }

        // M1 Pro/Max, M2+ — the usual home for every rail.
        merge(IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue())
        // Base M1 (MacBook Air) exposes ANE/GPU/DRAM/E-P power here instead. sample() adopts these
        // values only when Energy Model showed no ANE, so merging is a no-op where PMP is empty.
        merge(IOReportCopyChannelsInGroup("PMP" as CFString, "Energy Counters" as CFString, 0, 0, 0)?
            .takeRetainedValue())

        // Last resort: neither group answered by name. A renamed group would land here (the
        // channels still exist — `sample()` matches group names tolerantly), and so would a part
        // that keeps its rails somewhere we have never seen. Costly enough to be worth avoiding —
        // it subscribes to every channel on the machine — so it runs ONLY when the named lookups
        // came back empty, i.e. on a machine that would otherwise report no power whatsoever.
        if merged == nil {
            merge(IOReportCopyAllChannels(0, 0)?.takeRetainedValue())
        }

        guard let channelSet = merged else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, channelSet, &subbed, 0, nil),
              let channels = subbed?.takeRetainedValue()
        else {
            return nil
        }
        self.subscription = sub
        self.subscribedChannels = channels
    }

    /// Takes a power reading averaged over `interval` seconds.
    public func sample(interval: TimeInterval = 0.2) -> PowerSample {
        let first = IOReportCreateSamples(subscription, subscribedChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(subscription, subscribedChannels, nil)

        guard let a = first?.takeRetainedValue(),
              let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            return PowerSample()
        }

        var result = PowerSample()
        let seconds = max(interval, 0.001)
        // PMP "Energy Counters" accumulators — adopted only if Energy Model exposes no ANE (base M1).
        var pmpECpu = 0.0, pmpPCpu = 0.0, pmpGpu = 0.0, pmpAne = 0.0, pmpDram = 0.0
        var sawEnergyModelANE = false

        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatSimple,
                  let groupRef = IOReportChannelGetGroup(channel)?.takeUnretainedValue(),
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }

            let group = groupRef as String
            let name = nameRef as String
            let milliJoules = Double(IOReportSimpleGetIntegerValue(channel, 0))
            let watts = (milliJoules / seconds) / 1000.0

            // Group and channel names are matched through IOReportNaming so a die/chip-id token
            // ("DIE0 Energy Model", "DIE0 GPU0") still resolves — the shape that broke the
            // bandwidth group on a macOS 27 beta (#14) and that #35 reports for power. On a
            // machine whose names are bare, every check below behaves exactly as before.
            if IOReportNaming.isUnit(group, "Energy Model") {
                if IOReportNaming.isUnit(name, "CPU Energy") {
                    result.cpuWatts += watts
                } else if name.hasSuffix("_CPU") {
                    // Rails map to PERF LEVELS, not to the words "efficiency" and "performance".
                    //
                    // ⚠️ The `_CPU` suffix is what picks the CLUSTER TOTAL out of a family that also
                    // contains per-core rails and a fabric rail: `EACC_CPU` (total) sits beside
                    // `EACC_CPU0`/`EACC_CPU1` (cores) and `EACC_CPM` (fabric). Summing the family
                    // would double-count the cluster.
                    if IOReportNaming.hasUnitPrefix(name, "EACC") {
                        result.eCPUWatts += watts        // perflevel 1
                    } else if IOReportNaming.hasUnitPrefix(name, "PACC") {
                        result.pCPUWatts += watts        // perflevel 0
                    }
                } else if let level = m5ClusterLevel(name) {
                    // M5 Max names its rails differently: the cluster totals are bare `PCPU`
                    // (perflevel 0, "Super") and `MCPU0`/`MCPU1` (perflevel 1, "Performance") with
                    // **no `_CPU` suffix at all**, which is why the branch above matched nothing
                    // there and both rows read 0.0 W (#30). Per-core (`PACC_0…5`, `MCPU0_0…`),
                    // SRAM and fabric (`PCPM`, `MCPM0/1`) rails are deliberately NOT summed — the
                    // same double-counting rule as above, and the reason this matches cluster names
                    // exactly rather than by prefix.
                    //
                    // Safe to add unconditionally: M1–M4 expose no bare `PCPU`/`MCPU*` channel in
                    // Energy Model (verified on M1 Max), so the two shapes never both fire.
                    if level == 0 { result.pCPUWatts += watts } else { result.eCPUWatts += watts }
                } else if IOReportNaming.hasUnitPrefix(name, "GPU")
                            && !IOReportNaming.isUnit(name, "GPU Energy") {
                    result.gpuWatts += watts             // GPU0 + GPU SRAM0
                } else if IOReportNaming.hasUnitPrefix(name, "ANE") {
                    result.aneWatts += watts             // ANE0, ANE1 (estimate)
                    sawEnergyModelANE = true
                } else if IOReportNaming.hasUnitPrefix(name, "DRAM") {
                    result.dramWatts += watts            // DRAM0
                }
            } else if IOReportNaming.isUnit(group, "PMP") {
                // Base-M1 fallback source. Only the "Energy Counters" subgroup carries the rails;
                // match cluster totals (ECPU/PCPU), not per-core (ECORE*/PCORE*).
                let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                guard IOReportNaming.isUnit(subgroup, "Energy Counters") else {
                    return Int32(kKtopIOReportIterOk)
                }
                // Whole-unit matches (not prefixes): these rails are cluster/engine TOTALS, and a
                // prefix would also swallow the per-core siblings and double-count them.
                if IOReportNaming.isUnit(name, "ANE") {
                    pmpAne  += watts
                } else if IOReportNaming.isUnit(name, "GPU") || IOReportNaming.isUnit(name, "GPU SRAM") {
                    pmpGpu  += watts
                } else if IOReportNaming.isUnit(name, "DRAM") {
                    pmpDram += watts
                } else if IOReportNaming.isUnit(name, "ECPU") {
                    pmpECpu += watts                       // perflevel 1
                } else if ["MCPU", "MCPU0", "MCPU1"].contains(where: { IOReportNaming.isUnit(name, $0) }) {
                    pmpECpu += watts                       // M5's perflevel 1
                } else if IOReportNaming.isUnit(name, "PCPU") {
                    pmpPCpu += watts                       // perflevel 0 (Performance, or Super)
                }
            }
            return Int32(kKtopIOReportIterOk)
        }

        // M5-shape cluster totals: exactly "PCPU"/"MCPU" plus an optional cluster number, and
        // nothing else — no underscore (per-core / SRAM) and no "CPM" (fabric).
        func m5ClusterLevel(_ name: String) -> Int? {
            // Inspect the unit's own token so a leading chip-id survives ("PRIM MCPU0" → "MCPU0",
            // the spelling #30's reporter saw). Single-token unit, so `unitToken` is safe here.
            let unit = IOReportNaming.unitToken(name)
            for (prefix, level) in [("PCPU", 0), ("MCPU", 1)] where unit.hasPrefix(prefix) {
                let rest = unit.dropFirst(prefix.count)
                if rest.isEmpty || rest.allSatisfy(\.isNumber) { return level }
            }
            return nil
        }

        // Base M1: "Energy Model" has no ANE channel, so its ANE/GPU/DRAM/E-P rails read 0 — adopt
        // the "PMP" "Energy Counters" values instead. M1 Pro/Max/M2+ expose ANE in Energy Model, so
        // this never fires there and PMP is left untouched (same shape as the A18 SMC fallback below).
        if !sawEnergyModelANE {
            result.aneWatts = pmpAne
            result.gpuWatts = pmpGpu
            result.dramWatts = pmpDram
            result.eCPUWatts = pmpECpu
            result.pCPUWatts = pmpPCpu
            if result.cpuWatts == 0 { result.cpuWatts = pmpECpu + pmpPCpu }
        }

        // A18: Energy Model only exposes GPU, so cpu/ane/dram stay 0 and the derived sum is wrong.
        // Read the real rails from SMC instead (confirmed by Dreaminko's load test, #12):
        //   PSTR = system total (direct watts); PZC0 = CPU package power.
        // PZC0 ≈ PZC1 (both ~0.8W idle, ~6.2W under load) — the same CPU reading, not two clusters,
        // so use one (their sum would exceed PSTR). The E/P split isn't exposed on the A18.
        if isA18 {
            if let pstr = smc?.readDouble("PSTR") { result.measuredSocWatts = pstr }
            if let cpu = smc?.readDouble("PZC0") { result.cpuWatts = cpu }
        }

        return result
    }

    /// One IOReport "Simple" (energy) channel, as read for a diagnostic dump.
    public struct ChannelRow: Sendable, Equatable {
        public let group: String
        public let subgroup: String
        public let name: String
        public let raw: Int
        public let watts: Double

        /// `[group] (subgroup) name = W (raw)` — the line shape issues have quoted since v1.
        public var line: String {
            let sg = subgroup.isEmpty ? "" : " (\(subgroup))"
            return "[\(group)]\(sg) \(name) = \(String(format: "%.3f", watts)) W  (raw \(raw))"
        }
    }

    /// Every IOReport "Simple" channel on the machine, across ALL groups, so contributors on
    /// unverified chips can report exactly where a rail is exposed. Motivating case: ANE power on
    /// M2 may sit in the "PMP" group rather than "Energy Model".
    ///
    /// ⚠️ This is ~9,000 rows on an M1 Max — most of it interrupt and network statistics. Anything
    /// asking a REPORTER to paste something must summarise first (see `channelSummary`); a dump
    /// nobody can paste is a diagnostic that does not exist, which is how #35 stalled.
    public static func channelRows(interval: TimeInterval = 0.3) -> [ChannelRow] {
        guard let all = IOReportCopyAllChannels(0, 0)?.takeRetainedValue() else { return [] }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, all, &subbed, 0, nil),
              let channels = subbed?.takeRetainedValue() else { return [] }
        let first = IOReportCreateSamples(sub, channels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(sub, channels, nil)
        guard let a = first?.takeRetainedValue(), let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue() else { return [] }
        let seconds = max(interval, 0.001)

        var rows: [ChannelRow] = []
        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatSimple,
                  let groupRef = IOReportChannelGetGroup(channel)?.takeUnretainedValue(),
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }
            let raw = IOReportSimpleGetIntegerValue(channel, 0)
            rows.append(ChannelRow(
                group: groupRef as String,
                subgroup: (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? "",
                name: nameRef as String,
                raw: raw,
                watts: Double(raw) / seconds / 1000.0))   // Energy Model is mJ; other groups may differ
            return Int32(kKtopIOReportIterOk)
        }
        return rows
    }

    /// The short, pasteable half of `--power-debug`: which groups exist and what this build would
    /// actually read from them. A renamed or absent power group — the shape #35 reports, where
    /// every wattage reads 0.0 while everything else works — is visible in these few lines without
    /// anyone scrolling nine thousand rows.
    public static func channelSummary(_ rows: [ChannelRow]) -> [String] {
        guard !rows.isEmpty else { return ["IOReport unavailable or returned no Simple channels."] }

        var lines: [String] = []
        // Does a group this sampler knows how to read exist at all? This is the whole question.
        for wanted in ["Energy Model", "PMP"] {
            let found = Set(rows.map(\.group)).filter { IOReportNaming.isUnit($0, wanted) }
            lines.append(found.isEmpty
                ? "  \(wanted): ABSENT  ← every wattage will read 0.0 W"
                : "  \(wanted): present as \(found.sorted().map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        // Groups whose name merely LOOKS power-related, so a rename to something we do not know
        // still shows up here rather than being invisible.
        let powerish = Set(rows.map(\.group)).filter { g in
            let u = g.uppercased()
            return u.contains("ENERGY") || u.contains("POWER") || u.contains("PMP")
        }
        lines.append("  power-like groups present: " +
                     (powerish.isEmpty ? "(none)" : powerish.sorted().joined(separator: ", ")))

        // The rails themselves, so a channel rename is visible beside the group answer.
        let rails = rows
            .filter { r in
                IOReportNaming.isUnit(r.group, "Energy Model") || IOReportNaming.isUnit(r.group, "PMP")
            }
            .filter { $0.raw != 0 || IOReportNaming.hasUnitPrefix($0.name, "ANE") }
            .sorted { $0.line < $1.line }
        lines.append("  non-zero rails in those groups (plus every ANE channel): \(rails.count)")
        lines.append(contentsOf: rails.prefix(40).map { "    " + $0.line })
        if rails.count > 40 { lines.append("    … \(rails.count - 40) more (add --full to list them)") }
        return lines
    }

    /// Formatted full dump, sorted so groups cluster. Kept for callers that want every row.
    public static func channelDump(interval: TimeInterval = 0.3) -> [String] {
        let rows = channelRows(interval: interval)
        guard !rows.isEmpty else { return ["IOReport unavailable (non-Apple-Silicon?)"] }
        return rows.map(\.line).sorted()
    }
}
