//
//  File:      PowerSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads per-domain SoC power (CPU E/P, GPU, ANE, DRAM) sudolessly via
//             the private IOReport framework. Subscribes once, then each sample()
//             takes two snapshots `interval` apart and converts the delta to Watts.
//  Notes:     Energy unit is millijoules: Watts = (mJ delta / seconds) / 1000.
//             Everything lives in the "Energy Model" group: CPU Energy = total CPU,
//             EACC*_CPU = E clusters, PACC*_CPU = P clusters, GPU0/GPU SRAM0 = GPU,
//             ANE0/ANE1 = Neural Engine, DRAM0 = memory. "GPU Energy" is excluded
//             (different unit, ~nJ). PMP group carries no usable power channels on
//             M-series (verified M1 Max). Only Simple-format channels hold energy.
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

            guard group == "Energy Model" else { return Int32(kKtopIOReportIterOk) }

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
            } else if name.hasPrefix("DRAM") {
                result.dramWatts += watts            // DRAM0
            }
            return Int32(kKtopIOReportIterOk)
        }

        // A18: Energy Model only exposes GPU, so cpu/ane/dram stay 0 and the derived sum is wrong.
        // SMC PSTR is the true system total (direct watts) — surface it as the SoC total.
        if isA18, let pstr = smc?.readDouble("PSTR") { result.measuredSocWatts = pstr }

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
