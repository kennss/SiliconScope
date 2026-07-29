//
//  File:      CPUClusterMap.swift
//  Created:   2026-07-29
//  Updated:   2026-07-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads which CPU index belongs to which physical cluster, from the IODeviceTree, plus
//             every non-empty `voltage-states*` DVFS table under AppleARMIODevice. Both are the
//             inputs `CPUTopology` needs to stop GUESSING the E/P split on a chip whose perf levels
//             are not named "Efficiency" and "Performance" (#30, Apple M5's **Super** cluster).
//  Notes:     ⚠️ macOS exposes core COUNTS per perf level (`hw.perflevelN.logicalcpu`) but **no
//             sysctl for the ORDER** — verified by enumerating every `hw.perflevel*` key. So the
//             mapping from `host_processor_info` index → cluster has to come from the device tree,
//             where each `cpuN@…` node carries `logical-cluster-id`, `cluster-type` ("E"/"P"/…) and
//             `cluster-core-id`. Measured on M1 Max: cpu0–1 = cluster 0 "E", cpu2–5 = cluster 1 "P",
//             cpu6–9 = cluster 2 "P" — i.e. the LOWER perf tier is enumerated first.
//             ⚠️ Cluster sizes alone cannot identify a level: M5 Max is 6+6+6 (one Super cluster
//             plus two Performance clusters), so 6 vs 12 has several groupings. `cluster-type` is
//             what disambiguates, which is exactly why this dump exists before the fix.
//             All sudoless — IORegistry reads only.
//
import Foundation
import IOKit

/// One CPU as the device tree describes it.
public struct CPUClusterEntry: Sendable, Equatable {
    /// `host_processor_info` index — the ordering every usage split depends on.
    public let cpuIndex: Int
    public let clusterID: Int
    /// "E", "P", … as reported. Empty when the property is absent.
    public let clusterType: String
    public let coreInCluster: Int

    public init(cpuIndex: Int, clusterID: Int, clusterType: String, coreInCluster: Int) {
        self.cpuIndex = cpuIndex
        self.clusterID = clusterID
        self.clusterType = clusterType
        self.coreInCluster = coreInCluster
    }
}

public enum CPUClusterMap {

    // MARK: - Device-tree cluster map

    /// Every CPU node, ascending by index. Empty when the device tree does not carry the
    /// properties — callers must keep working without it.
    public static func read() -> [CPUClusterEntry] {
        var entries: [CPUClusterEntry] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOPlatformDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer { entry = IOIteratorNext(iterator) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS else { IOObjectRelease(entry); continue }
            let name = String(cString: nameBuf)
            // Node names are "cpu0", "cpu1", … — anything else in IOPlatformDevice is not a core.
            guard name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)) else { IOObjectRelease(entry); continue }

            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as NSDictionary? {
                entries.append(CPUClusterEntry(
                    cpuIndex: index,
                    clusterID: intValue(dict["logical-cluster-id"]) ?? -1,
                    clusterType: stringValue(dict["cluster-type"]) ?? "",
                    coreInCluster: intValue(dict["cluster-core-id"]) ?? -1))
            }
            IOObjectRelease(entry)
        }
        return entries.sorted { $0.cpuIndex < $1.cpuIndex }
    }

    // MARK: - DVFS tables

    /// Every non-empty `voltage-states*` table under AppleARMIODevice, keyed by property name.
    ///
    /// The pair `5-sram` / `1-sram` is what `CPUTopology` reads today; on M5 Max `1-sram` is absent
    /// entirely (hence "E-cores @ 0 MHz") and the second cluster's table is `22-sram` / `23-sram`.
    /// Dumping ALL of them is how the next chip gets diagnosed in one command instead of a round trip.
    public static func voltageStateTables() -> [String: [Double]] {
        var tables: [String: [Double]] = [:]
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"),
                                           &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer { entry = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { IOObjectRelease(entry); continue }
            for (key, value) in dict where key.hasPrefix("voltage-states") {
                guard let data = value as? Data else { continue }
                let freqs = decodeVoltageStates(data)
                if !freqs.isEmpty { tables[key] = freqs }
            }
            IOObjectRelease(entry)
        }
        return tables
    }

    /// Decodes a `(frequency, voltage)` uint32 pair table to MHz.
    ///
    /// ⚠️ Unit heuristic, not a per-chip branch: M1–M3 store CPU frequencies in Hz, M4 and M5 in
    /// KHz. A KHz table read as Hz yields a ~1–5 "MHz" maximum, which no DVFS table has, so an
    /// implausibly low maximum means the source was KHz.
    public static func decodeVoltageStates(_ data: Data) -> [Double] {
        var freqs: [Double] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let words = raw.bindMemory(to: UInt32.self)
            var i = 0
            while i < words.count {
                let hz = words[i]              // frequency word; the voltage word follows
                if hz != 0 { freqs.append(Double(hz) / 1_000_000.0) }
                i += 2
            }
        }
        if let peak = freqs.max(), peak > 0, peak < 100 { freqs = freqs.map { $0 * 1000 } }
        return freqs
    }

    // MARK: - Property helpers (IORegistry values arrive as NSNumber *or* Data)

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Data, d.count >= 4 {
            return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let d = any as? Data {
            let text = String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
