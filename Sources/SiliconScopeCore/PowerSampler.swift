//
//  File:      PowerSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-07-02
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads per-domain SoC power (CPU E/P, GPU, ANE, DRAM) sudolessly via
//             the private IOReport framework. Subscribes once, then each sample()
//             takes two snapshots `interval` apart and converts the delta to Watts.
//  Notes:     Energy unit is millijoules: Watts = (mJ delta / seconds) / 1000.
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

    /// Returns nil if IOReport is unavailable (e.g. non-Apple-Silicon hardware).
    public init?() {
        guard let energy = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?
            .takeRetainedValue()
        else {
            return nil
        }
        // Base M1 (MacBook Air) exposes ANE/GPU/DRAM/E-P power in the "PMP" group's "Energy
        // Counters" subgroup, not "Energy Model". Subscribe to both and merge; sample() falls back
        // to PMP only when Energy Model has no ANE channel (a no-op on chips whose PMP is empty).
        if let pmp = IOReportCopyChannelsInGroup("PMP" as CFString, "Energy Counters" as CFString, 0, 0, 0)?
            .takeRetainedValue() {
            IOReportMergeChannels(energy, pmp, nil)
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, energy, &subbed, 0, nil),
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

            if group == "Energy Model" {
                if name == "CPU Energy" {
                    result.cpuWatts += watts
                } else if name.hasSuffix("_CPU") {
                    if name.hasPrefix("EACC") {
                        result.eCPUWatts += watts        // efficiency clusters
                    } else if name.hasPrefix("PACC") {
                        result.pCPUWatts += watts        // performance clusters
                    }
                } else if name.hasPrefix("GPU") && name != "GPU Energy" {
                    result.gpuWatts += watts             // GPU0 + GPU SRAM0
                } else if name.hasPrefix("ANE") {
                    result.aneWatts += watts             // ANE0, ANE1 (estimate)
                    sawEnergyModelANE = true
                } else if name.hasPrefix("DRAM") {
                    result.dramWatts += watts            // DRAM0
                }
            } else if group == "PMP" {
                // Base-M1 fallback source. Only the "Energy Counters" subgroup carries the rails;
                // match cluster totals (ECPU/PCPU), not per-core (ECORE*/PCORE*).
                let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                guard subgroup == "Energy Counters" else { return Int32(kKtopIOReportIterOk) }
                switch name {
                case "ANE":             pmpAne  += watts
                case "GPU", "GPU SRAM": pmpGpu  += watts
                case "DRAM":            pmpDram += watts
                case "ECPU":            pmpECpu += watts
                case "PCPU":            pmpPCpu += watts
                default:                break
                }
            }
            return Int32(kKtopIOReportIterOk)
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

    /// Diagnostic dump of every IOReport "Simple" (energy) channel across ALL groups —
    /// `[group] (subgroup) name = W (raw)` — so contributors on unverified chips can report
    /// exactly where a rail is exposed. Motivating case: ANE power on M2 may sit in the "PMP"
    /// group rather than "Energy Model" (which is all `sample()` scans). Surfaced by
    /// `sscope-cli --power-debug`. One line per channel, sorted so groups cluster.
    public static func channelDump(interval: TimeInterval = 0.3) -> [String] {
        guard let all = IOReportCopyAllChannels(0, 0)?.takeRetainedValue() else {
            return ["IOReport unavailable (non-Apple-Silicon?)"]
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, all, &subbed, 0, nil),
              let channels = subbed?.takeRetainedValue() else {
            return ["IOReport subscription failed"]
        }
        let first = IOReportCreateSamples(sub, channels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(sub, channels, nil)
        guard let a = first?.takeRetainedValue(), let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue() else {
            return ["IOReport sampling failed"]
        }
        let seconds = max(interval, 0.001)

        var lines: [String] = []
        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatSimple,
                  let groupRef = IOReportChannelGetGroup(channel)?.takeUnretainedValue(),
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }
            let group = groupRef as String
            let name = nameRef as String
            let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            let raw = IOReportSimpleGetIntegerValue(channel, 0)
            let watts = Double(raw) / seconds / 1000.0   // Energy Model is mJ; other groups may differ
            let sg = subgroup.isEmpty ? "" : " (\(subgroup))"
            lines.append("[\(group)]\(sg) \(name) = \(String(format: "%.3f", watts)) W  (raw \(raw))")
            return Int32(kKtopIOReportIterOk)
        }
        return lines.sorted()
    }
}
