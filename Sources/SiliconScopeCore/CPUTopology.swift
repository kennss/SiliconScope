//
//  File:      CPUTopology.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Static Apple Silicon CPU topology: efficiency/performance core counts
//             (sysctl) and the per-cluster DVFS frequency tables (IORegistry).
//  Notes:     perflevel0 = "Performance" (P), perflevel1 = "Efficiency" (E).
//             DVFS tables come from AppleARMIODevice voltage-states: each blob is a
//             (freq, voltage) UInt32 pair array; zero entries skipped. M1–M3 store freq
//             in Hz (÷1e6 = MHz); M4 switched the CPU tables to KHz, so readVoltageStates
//             rescales ×1000 when the Hz reading is implausibly low (see there).
//             voltage-states1-sram = E cluster, voltage-states5-sram = P. All sudoless.
//
import Foundation
import IOKit

public struct CPUTopology: Sendable, Codable {
    public let chipName: String         // e.g. "Apple M1 Max"
    public let eCoreCount: Int
    public let pCoreCount: Int
    public let eFreqsMHz: [Double]      // ascending DVFS steps
    public let pFreqsMHz: [Double]
    public let gpuFreqsMHz: [Double]    // GPU DVFS steps (voltage-states9)

    public static func detect() -> CPUTopology {
        let level0Name = sysctlString("hw.perflevel0.name") ?? "Performance"
        let level0Count = sysctlInt("hw.perflevel0.logicalcpu")
        let level1Count = sysctlInt("hw.perflevel1.logicalcpu")
        let perfIsLevel0 = level0Name.lowercased().contains("perf")

        return CPUTopology(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            eCoreCount: perfIsLevel0 ? level1Count : level0Count,
            pCoreCount: perfIsLevel0 ? level0Count : level1Count,
            eFreqsMHz: readVoltageStates("voltage-states1-sram"),
            pFreqsMHz: readVoltageStates("voltage-states5-sram"),
            gpuFreqsMHz: readVoltageStates("voltage-states9")
        )
    }

    // MARK: - sysctl helpers

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    // MARK: - DVFS table (IORegistry)

    private static func readVoltageStates(_ key: String) -> [Double] {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("AppleARMIODevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var freqs: [Double] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as NSDictionary?,
               let data = dict[key] as? Data {
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let words = raw.bindMemory(to: UInt32.self)
                    var i = 0
                    while i < words.count {
                        let hz = words[i]                 // freq word; voltage word follows
                        if hz != 0 { freqs.append(Double(hz) / 1_000_000.0) }
                        i += 2
                    }
                }
                IOObjectRelease(entry)
                break
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        // Unit fix: M1–M3 store these CPU freqs in Hz (÷1e6 above → MHz). M4 switched the same
        // voltage-states*-sram tables to KHz, so the Hz interpretation yields ~1–5 "MHz". Real
        // DVFS maxes are 600–4500 MHz, so when the computed max is implausibly low the source
        // was KHz — rescale ×1000. Self-correcting across chip generations (no per-chip branch);
        // GPU voltage-states9 stays Hz on M4 and reads plausibly, so it is left untouched.
        if let maxFreq = freqs.max(), maxFreq > 0, maxFreq < 100 {
            freqs = freqs.map { $0 * 1000 }
        }
        return freqs
    }
}
