//
//  File:      CPUTopology.swift
//  Created:   2026-06-08
//  Updated:   2026-07-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Static Apple Silicon CPU topology: the two perf levels' core counts (sysctl), their
//             names, and the per-cluster DVFS frequency tables (IORegistry).
//  Notes:     ⚠️ The two slots are **perf LEVELS**, not "P and E". Apple orders perf levels
//             fastest-first: level 0 is "Performance" on M1–M4 but **"Super"** on M5 Max, whose
//             level 1 is called "Performance" and which has no Efficiency level at all. The
//             `eCoreCount`/`pCoreCount` field names are kept because they cross the fleet wire
//             (`FleetCPU`), but they mean level 1 / level 0 — read `eLabel`/`pLabel` for display.
//             DVFS tables come from AppleARMIODevice voltage-states: each blob is a
//             (freq, voltage) UInt32 pair array; zero entries skipped. M1–M3 store freq
//             in Hz (÷1e6 = MHz); M4 and M5 switched the CPU tables to KHz, so readVoltageStates
//             rescales ×1000 when the Hz reading is implausibly low (see there).
//             Level 0 is `voltage-states5-sram` on every chip measured; level 1 is `1-sram` on M1
//             and `22/23-sram` on M5 Max — a candidate list, not a rule (see `dvfsTable`).
//             All sudoless.
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

    /// What macOS calls each perf level — the UI's labels, instead of a hardcoded "P-cores" /
    /// "E-cores". `hw.perflevel0.name` is "Performance" on M1–M4 and **"Super"** on M5 Max, whose
    /// second level is called "Performance" and whose Efficiency level does not exist.
    ///
    /// ⚠️ Optional because a REMOTE Mac does not send them: the fleet agent is a separately
    /// installed binary, so an older one reports core counts with no names. `nil` then means
    /// "unknown", and the UI falls back to E/P rather than inventing a label.
    public let pLevelName: String?
    public let eLevelName: String?

    /// Display labels, e.g. "Super" / "Performance" on M5 Max, "P-cores" / "E-cores" elsewhere.
    public var pLabel: String { pLevelName ?? "P-cores" }
    public var eLabel: String { eLevelName ?? "E-cores" }

    /// Compact core breakdown for the window header: "2E+8P" when the levels are the familiar
    /// Efficiency/Performance pair, "6 Super + 12 Performance" when they are not — a chip whose
    /// levels have other names must not be described with letters that mean something else.
    public var coreSummary: String {
        guard let p = pLevelName, let e = eLevelName else { return "\(eCoreCount)E+\(pCoreCount)P" }
        let classic = p.lowercased().hasPrefix("perf") && e.lowercased().hasPrefix("eff")
        return classic ? "\(eCoreCount)E+\(pCoreCount)P"
                       : "\(pCoreCount) \(p) + \(eCoreCount) \(e)"
    }

    public init(chipName: String, eCoreCount: Int, pCoreCount: Int,
                eFreqsMHz: [Double], pFreqsMHz: [Double], gpuFreqsMHz: [Double],
                pLevelName: String? = nil, eLevelName: String? = nil) {
        self.chipName = chipName
        self.eCoreCount = eCoreCount
        self.pCoreCount = pCoreCount
        self.eFreqsMHz = eFreqsMHz
        self.pFreqsMHz = pFreqsMHz
        self.gpuFreqsMHz = gpuFreqsMHz
        self.pLevelName = pLevelName
        self.eLevelName = eLevelName
    }

    /// One entry of `hw.perflevelN.*`.
    public struct PerfLevel: Sendable, Equatable {
        public let index: Int
        public let name: String
        public let logicalCPUs: Int
        public let physicalCPUs: Int
    }

    public static func perfLevelCount() -> Int { max(sysctlInt("hw.nperflevels"), 1) }

    /// Every perf level macOS reports, in Apple's order — which is **fastest first**.
    public static func perfLevels() -> [PerfLevel] {
        (0..<perfLevelCount()).map { i in
            PerfLevel(index: i,
                      name: sysctlString("hw.perflevel\(i).name") ?? (i == 0 ? "Performance" : "Efficiency"),
                      logicalCPUs: sysctlInt("hw.perflevel\(i).logicalcpu"),
                      physicalCPUs: sysctlInt("hw.perflevel\(i).physicalcpu"))
        }
    }

    public static func detect() -> CPUTopology {
        let levels = perfLevels()
        let level0 = levels.first
        let level1 = levels.count > 1 ? levels[1] : nil

        // ⚠️ The slots are **perf LEVELS**, not "P and E". Apple orders perf levels fastest-first,
        // so level 0 is always the top tier and level 1 the one below it — true on M1 (Performance
        // + Efficiency) and on M5 Max (**Super** + Performance, no Efficiency level at all).
        //
        // The retired rule asked whether the level's NAME contained "perf". "Super" does not, so an
        // M5 Max put its 6 Super cores in the E slot and its 12 Performance cores in the P slot —
        // the "6E+12P" header, and the E slot then read `voltage-states1-sram`, which that chip
        // does not have: the "E-cores @ 0 MHz" reading (#30).
        //
        // ⚠️ Levels beyond the first two are ignored — Apple has never shipped one, and inventing a
        // third slot for the whole app on speculation is worse than saying so here. `--cpu-debug`
        // prints the real count, so the day it happens it is one command to find out.
        return CPUTopology(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            eCoreCount: level1?.logicalCPUs ?? 0,
            pCoreCount: level0?.logicalCPUs ?? 0,
            eFreqsMHz: dvfsTable(forLevel: 1),
            pFreqsMHz: dvfsTable(forLevel: 0),
            gpuFreqsMHz: readVoltageStates("voltage-states9"),
            pLevelName: level0?.name,
            eLevelName: level1?.name
        )
    }

    /// Which `host_processor_info` indices belong to the SECOND perf level (the "E" slot).
    ///
    /// ⚠️ macOS publishes core counts per perf level but **no order** — every `hw.perflevel*` key
    /// was enumerated and none of them says which indices they are. The device tree does:
    /// each `cpuN` node carries `cluster-type` and `logical-cluster-id`.
    ///
    /// Resolution order, most reliable first:
    /// 1. **By cluster type** — group the map by `cluster-type` and take the group whose total
    ///    matches level 1's count. On M1 Max that is "E"=2 against "P"=4+4, unambiguous.
    /// 2. **By contiguous prefix** — the retired assumption ("the lower tier is enumerated first"),
    ///    which the M1 Max device tree confirms (cpu0–1 = cluster 0 = Efficiency).
    ///
    /// ⚠️ Step 2 is not safe on its own where every cluster is the same size: M5 Max is 6+6+6
    /// (Super + two Performance), so a 12-core prefix could be Super + one Performance cluster.
    /// That is precisely why step 1 exists and why `--cpu-debug` prints the types.
    public static func secondLevelIndices(coreCount: Int, level1Count: Int) -> Range<Int> {
        guard level1Count > 0, level1Count < coreCount else { return 0..<min(level1Count, coreCount) }
        let map = CPUClusterMap.read()

        if !map.isEmpty {
            let byType = Dictionary(grouping: map.filter { !$0.clusterType.isEmpty }, by: \.clusterType)
            if byType.count > 1,
               let match = byType.first(where: { $0.value.count == level1Count })?.value {
                let indices = match.map(\.cpuIndex).sorted()
                // Only trust it when the group is contiguous — the samplers slice a range.
                if let lo = indices.first, let hi = indices.last, hi - lo + 1 == indices.count {
                    return lo..<(hi + 1)
                }
            }
        }
        return 0..<level1Count
    }

    /// DVFS table for a perf level.
    ///
    /// ⚠️ A candidate LIST, not a rule — because no rule is visible in the data. Level 0 is
    /// `voltage-states5-sram` on both M1 and M5 Max, but level 1 is `1-sram` on M1 and `22-sram` /
    /// `23-sram` (identical twins, one per Performance cluster) on M5 Max, where `1-sram` is absent
    /// entirely. First non-empty candidate wins; `--cpu-debug` prints every table present so the
    /// next chip is one command away instead of one round trip.
    private static func dvfsTable(forLevel level: Int) -> [Double] {
        let candidates = level == 0
            ? ["voltage-states5-sram"]
            : ["voltage-states1-sram", "voltage-states22-sram", "voltage-states23-sram"]
        for key in candidates {
            let table = readVoltageStates(key)
            if !table.isEmpty { return table }
        }
        return []
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
