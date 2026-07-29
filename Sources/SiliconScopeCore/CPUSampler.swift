//
//  File:      CPUSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-08
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads per-cluster CPU usage and average clock (E vs P) sudolessly.
//             Usage uses host_processor_info CPU ticks (busy / total per core, averaged
//             per cluster) to match Activity Monitor / iStat. Frequency uses IOReport
//             "CPU Stats" residency weighted by the DVFS table.
//  Notes:     Earlier versions derived usage from IOReport *complex* residency, which
//             reports "cluster not fully idle" and over-counts (≈100% if any core is
//             busy). Tick-based per-core averaging is the correct utilization.
//             Apple Silicon enumerates efficiency cores first (indices 0..<eCoreCount).
//
import Foundation
import CIOReport

public final class CPUSampler {
    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary
    private let eFreqs: [Double]
    private let pFreqs: [Double]

    public let topology: CPUTopology

    private var previousBusy: [UInt64] = []
    private var previousTotal: [UInt64] = []

    public init?() {
        let topo = CPUTopology.detect()
        self.topology = topo
        self.eFreqs = topo.eFreqsMHz
        self.pFreqs = topo.pFreqsMHz

        guard let channels = IOReportCopyChannelsInGroup("CPU Stats" as CFString, nil, 0, 0, 0)?
            .takeRetainedValue()
        else {
            return nil
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, channels, &subbed, 0, nil),
              let subscribed = subbed?.takeRetainedValue()
        else {
            return nil
        }
        self.subscription = sub
        self.subscribedChannels = subscribed
    }

    public func sample(interval: TimeInterval = 0.2) -> CPUSample {
        var result = CPUSample()
        let usage = sampleUsage()
        result.eUsage = usage.e
        result.pUsage = usage.p
        let freq = sampleFrequency(interval: interval)
        result.eFreqMHz = freq.e
        result.pFreqMHz = freq.p
        return result
    }

    // MARK: - Usage (host_processor_info ticks, like Activity Monitor)

    private func sampleUsage() -> (e: Double, p: Double) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0) }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let count = Int(cpuCount)
        let states = Int(CPU_STATE_MAX)
        var busy = [UInt64](repeating: 0, count: count)
        var total = [UInt64](repeating: 0, count: count)
        for i in 0..<count {
            let user = UInt64(info[i * states + Int(CPU_STATE_USER)])
            let system = UInt64(info[i * states + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[i * states + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[i * states + Int(CPU_STATE_IDLE)])
            busy[i] = user + system + nice
            total[i] = user + system + nice + idle
        }
        defer { previousBusy = busy; previousTotal = total }

        guard previousBusy.count == count else { return (0, 0) }   // first call: no delta

        var perCore = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let deltaBusy = Double(busy[i] >= previousBusy[i] ? busy[i] - previousBusy[i] : 0)
            let deltaTotal = Double(total[i] >= previousTotal[i] ? total[i] - previousTotal[i] : 0)
            perCore[i] = deltaTotal > 0 ? deltaBusy / deltaTotal : 0
        }

        // ⚠️ Which indices belong to which perf level is READ, not assumed — the retired code took
        // the first `eCoreCount` cores, which is only right when the lower tier is enumerated first.
        // That held on M1–M4; on a chip whose levels are "Super" + "Performance" it mapped the
        // wrong cores (#30). `secondLevelIndices` prefers the device tree's cluster types.
        let range = CPUTopology.secondLevelIndices(coreCount: count,
                                                   level1Count: min(max(topology.eCoreCount, 0), count))
        let eCores = perCore[range.clamped(to: 0..<count)]
        let pCores = (0..<count).filter { !range.contains($0) }.map { perCore[$0] }
        let e = eCores.isEmpty ? 0 : eCores.reduce(0, +) / Double(eCores.count)
        let p = pCores.isEmpty ? 0 : pCores.reduce(0, +) / Double(pCores.count)
        return (e, p)
    }

    // MARK: - Frequency (IOReport residency × DVFS table)

    private func sampleFrequency(interval: TimeInterval) -> (e: Double, p: Double) {
        let first = IOReportCreateSamples(subscription, subscribedChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(subscription, subscribedChannels, nil)

        guard let a = first?.takeRetainedValue(),
              let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            return (0, 0)
        }

        let eFreqs = self.eFreqs
        let pFreqs = self.pFreqs
        var eActive = 0.0, eFreqAcc = 0.0
        var pActive = 0.0, pFreqAcc = 0.0

        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatState,
                  let subgroupRef = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue(),
                  (subgroupRef as String) == "CPU Complex Performance States",
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue()
            else {
                return Int32(kKtopIOReportIterOk)
            }

            let name = nameRef as String
            let isEfficiency = (name == "ECPU")
            let isPerformance = (name == "PCPU" || name == "PCPU1")
            guard isEfficiency || isPerformance else { return Int32(kKtopIOReportIterOk) }

            let freqs = isEfficiency ? eFreqs : pFreqs
            let stateCount = Int(IOReportStateGetCount(channel))
            var activeIndex = 0
            for i in 0..<stateCount {
                let residency = Double(IOReportStateGetResidency(channel, Int32(i)))
                let stateName = (IOReportStateGetNameForIndex(channel, Int32(i))?
                    .takeUnretainedValue() as String?) ?? ""
                if stateName == "IDLE" || stateName == "DOWN" || stateName == "OFF" { continue }
                let mhz = activeIndex < freqs.count ? freqs[activeIndex] : (freqs.last ?? 0)
                activeIndex += 1
                if isEfficiency {
                    eActive += residency
                    eFreqAcc += residency * mhz
                } else {
                    pActive += residency
                    pFreqAcc += residency * mhz
                }
            }
            return Int32(kKtopIOReportIterOk)
        }

        return (
            eActive > 0 ? eFreqAcc / eActive : 0,
            pActive > 0 ? pFreqAcc / pActive : 0
        )
    }
}
