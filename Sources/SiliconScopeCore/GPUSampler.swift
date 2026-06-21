//
//  File:      GPUSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-08
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads GPU utilization and average clock sudolessly via IOReport
//             "GPU Stats". Subscribes once; each sample() diffs two snapshots.
//  Notes:     Uses subgroup "GPU Performance States", channel "GPUPH" (State format):
//             state "OFF" is idle, "P1".."P15" are active DVFS steps mapped to the GPU
//             frequency table. usage = active / total residency.
//
import Foundation
import CIOReport
import Foundation
import IOKit

public final class GPUSampler {
    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary
    private let gpuFreqs: [Double]
    private let accelerator: io_service_t   // cached IOAccelerator service for GPU memory stats

    public init?(topology: CPUTopology) {
        self.gpuFreqs = topology.gpuFreqsMHz
        self.accelerator = Self.findAccelerator()
        guard let channels = IOReportCopyChannelsInGroup("GPU Stats" as CFString, nil, 0, 0, 0)?
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

    public func sample(interval: TimeInterval = 0.2) -> GPUSample {
        let first = IOReportCreateSamples(subscription, subscribedChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(subscription, subscribedChannels, nil)

        guard let a = first?.takeRetainedValue(),
              let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            return GPUSample()
        }

        let gpuFreqs = self.gpuFreqs
        var active = 0.0, total = 0.0, freqAcc = 0.0

        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatState,
                  let subgroupRef = IOReportChannelGetSubGroup(channel)?.takeUnretainedValue(),
                  (subgroupRef as String) == "GPU Performance States",
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue(),
                  (nameRef as String) == "GPUPH"
            else {
                return Int32(kKtopIOReportIterOk)
            }

            let stateCount = Int(IOReportStateGetCount(channel))
            var activeIndex = 0
            for i in 0..<stateCount {
                let residency = Double(IOReportStateGetResidency(channel, Int32(i)))
                let stateName = (IOReportStateGetNameForIndex(channel, Int32(i))?
                    .takeUnretainedValue() as String?) ?? ""
                total += residency
                if stateName == "OFF" || stateName == "IDLE" || stateName == "DOWN" { continue }

                let mhz = activeIndex < gpuFreqs.count ? gpuFreqs[activeIndex] : (gpuFreqs.last ?? 0)
                activeIndex += 1
                active += residency
                freqAcc += residency * mhz
            }
            return Int32(kKtopIOReportIterOk)
        }

        var result = GPUSample()
        result.usage = total > 0 ? active / total : 0
        result.freqMHz = active > 0 ? freqAcc / active : 0
        let mem = readGPUMemory()
        result.inUseMemoryBytes = mem.inUse
        result.allocatedMemoryBytes = mem.alloc
        return result
    }

    deinit { if accelerator != 0 { IOObjectRelease(accelerator) } }

    /// Finds the IOAccelerator service that exposes GPU memory stats (kept retained; the
    /// caller releases it in deinit). Returns 0 if none — memory then reads as zero.
    private static func findAccelerator() -> io_service_t {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any],
               let perf = d["PerformanceStatistics"] as? [String: Any],
               perf["In use system memory"] != nil {
                return svc   // keep this one
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return 0
    }

    /// GPU unified-memory footprint from IOAccelerator PerformanceStatistics.
    private func readGPUMemory() -> (inUse: UInt64, alloc: UInt64) {
        guard accelerator != 0 else { return (0, 0) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(accelerator, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any],
              let perf = d["PerformanceStatistics"] as? [String: Any] else { return (0, 0) }
        let inUse = (perf["In use system memory"] as? Int).map { UInt64(max(0, $0)) } ?? 0
        let alloc = (perf["Alloc system memory"] as? Int).map { UInt64(max(0, $0)) } ?? 0
        return (inUse, alloc)
    }
}
