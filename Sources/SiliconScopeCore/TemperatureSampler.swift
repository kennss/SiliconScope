//
//  File:      TemperatureSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads categorized temperatures sudolessly. Prefers the rich Apple Silicon
//             HID sensor set (IOHIDEventSystem, via HIDSensorReader) — the source iStat
//             uses, exposing the full per-unit die/SoC/NAND/battery set. Falls back to SMC
//             (Intel / older Macs), classifying keys by prefix and folding per-core sensors.
//  Notes:     HID names are raw PMU labels ("PMU tdie3", "NAND CH0 temp", "gas gauge
//             battery"); friendlyHID() strips/classifies them. SMC prefix map: Tp*=CPU,
//             Tg*=GPU, Tm*=Memory, TB*=Battery. Values outside (5,130)C are dropped.
//
import Foundation

public final class TemperatureSampler {
    private let smc: SMCReader?
    private let keysByCategory: [SensorCategory: [String]]
    private let coreCount: Int

    public init(coreCount: Int = 0) {
        let reader = SMCReader()
        self.smc = reader
        self.coreCount = coreCount

        var map: [SensorCategory: [String]] = [:]
        if let reader {
            for key in reader.temperatureKeys() {
                map[Self.category(for: key), default: []].append(key)
            }
        }
        self.keysByCategory = map.mapValues { $0.sorted() }
    }

    public func sample() -> TemperatureSample {
        // 1) Best: curated per-generation SMC keys read directly -> friendly per-unit names
        //    (P-Core / E-Core / GPU / Memory), the iStat-style breakdown.
        if let smc {
            let gen = SensorCatalog.detectGeneration()
            if gen != .unknown, let curated = Self.curatedSample(smc: smc, gen: gen) {
                // Some dies expose only a subset of their generation's keys (e.g. M4 Max reads
                // back no Memory key). For any category the table INTENDS but that didn't read,
                // fill it from the HID set so the panel isn't sparse — without fabricating the
                // per-core readings the chip genuinely doesn't expose. Fully-read chips (e.g.
                // M1) skip the HID read entirely, so there's no added cost or behavior change.
                let defined = Set(SensorCatalog.curated(for: gen).map(\.category))
                let missing = defined.subtracting(curated.groups.map(\.category))
                if !missing.isEmpty {
                    let hid = HIDSensorReader.read().filter { $0.celsius > 5 && $0.celsius < 130 }
                    if !hid.isEmpty { return Self.supplement(curated, withHID: hid, categories: missing) }
                }
                return curated
            }
        }

        // 2) Rich HID sensor set (Apple Silicon, but raw PMU names) for chips without a table.
        let hid = HIDSensorReader.read().filter { $0.celsius > 5 && $0.celsius < 130 }
        if !hid.isEmpty { return Self.buildSample(fromHID: hid) }

        // 3) SMC key scan (Intel / older Macs).
        var result = TemperatureSample()
        guard let smc else { return result }

        var groups: [SensorGroup] = []
        for category in SensorCategory.allCases {
            guard let keys = keysByCategory[category], !keys.isEmpty else { continue }

            var sensors: [TempSensor] = []
            for (index, key) in keys.enumerated() {
                guard let value = smc.readDouble(key), value > 5, value < 120 else { continue }
                let label = category == .other ? key : "\(category.rawValue) \(index + 1)"
                sensors.append(TempSensor(rawName: key, name: label, celsius: value))
            }
            // Apple Silicon exposes ~3 thermal sensors per CPU core; fold them back to
            // one reading per core (hottest of the group) so the count matches reality.
            if category == .cpu { sensors = foldToCores(sensors) }
            guard !sensors.isEmpty else { continue }

            let group = SensorGroup(category: category, sensors: sensors)
            groups.append(group)
            switch category {
            case .cpu:     result.cpuCelsius = group.average; result.cpuMaxCelsius = group.maximum
            case .gpu:     result.gpuCelsius = group.average
            case .battery: result.batteryCelsius = group.average
            default:       break
            }
        }
        result.groups = groups
        return result
    }

    /// Folds per-core sensor groups (sorted by key) into one reading per core, using
    /// the hottest sensor in each group. No-op unless the sensor count is a clean
    /// multiple of the core count.
    private func foldToCores(_ sensors: [TempSensor]) -> [TempSensor] {
        guard coreCount > 0, sensors.count > coreCount, sensors.count % coreCount == 0 else { return sensors }
        let perCore = sensors.count / coreCount
        return (0..<coreCount).map { core in
            let chunk = sensors[(core * perCore)..<((core + 1) * perCore)]
            let hottest = chunk.map(\.celsius).max() ?? 0
            return TempSensor(rawName: "cpu-core-\(core)", name: "CPU core \(core + 1)", celsius: hottest)
        }
    }

    /// Maps an SMC key to a friendly category by its documented Apple Silicon prefix.
    static func category(for key: String) -> SensorCategory {
        if key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("Tp") { return .cpu }      // CPU cores
        if key.hasPrefix("Tg") { return .gpu }
        if key.hasPrefix("Tm") { return .memory }
        return .other
    }

    /// Diagnostic readout for verifying / contributing sensor key tables: the detected
    /// generation plus every curated key with the value it reads back (nil = absent on this
    /// Mac, i.e. wrong/missing for this model). Surfaced by `sscope-cli --sensors` so a
    /// contributor on an unvalidated chip can confirm or correct the table.
    public func curatedReadout()
        -> (generation: String, entries: [(key: String, name: String, celsius: Double?)]) {
        let gen = SensorCatalog.detectGeneration()
        let entries = SensorCatalog.curated(for: gen).map { e -> (String, String, Double?) in
            let v = smc?.readDouble(e.key)
            let valid = (v.map { $0 > 5 && $0 < 130 } ?? false) ? v : nil
            return (e.key, e.name, valid)
        }
        return (String(describing: gen), entries)
    }

    /// Full dump of every SMC "T…" key present on this Mac (key · type · value), regardless of
    /// whether it's in the curated table. Lets contributors on unmapped chips (e.g. M4 Max)
    /// surface keys SiliconScope doesn't yet know — a missing sensor may live under an unknown
    /// FourCC. Surfaced by `sscope-cli --sensors-all`.
    public func allSMCKeys() -> [(key: String, type: String, celsius: Double?)] {
        smc?.allTemperatureKeys() ?? []
    }

    /// Reads the curated SMC key table for the detected Apple Silicon generation, directly
    /// (not by scanning), yielding friendly per-unit names. Returns nil if the chip is
    /// unknown or none of the keys read back (then the caller falls back to HID / scan).
    static func curatedSample(smc: SMCReader, gen: AppleSiliconGen) -> TemperatureSample? {
        var byCategory: [SensorCategory: [TempSensor]] = [:]
        for entry in SensorCatalog.curated(for: gen) {
            guard let value = smc.readDouble(entry.key), value > 5, value < 130 else { continue }
            byCategory[entry.category, default: []].append(
                TempSensor(rawName: entry.key, name: entry.name, celsius: value))
        }
        guard !byCategory.isEmpty else { return nil }

        var result = TemperatureSample()
        var groups: [SensorGroup] = []
        for category in SensorCategory.allCases {
            guard let sensors = byCategory[category], !sensors.isEmpty else { continue }
            let group = SensorGroup(category: category, sensors: sensors)   // table order
            groups.append(group)
            switch category {
            case .cpu:     result.cpuCelsius = group.average; result.cpuMaxCelsius = group.maximum
            case .gpu:     result.gpuCelsius = group.average
            case .battery: result.batteryCelsius = group.average
            default:       break
            }
        }
        result.groups = groups
        return result
    }

    /// Adds the given categories (intended by the curated table, but absent on this die) from
    /// the HID sensor set. Categories already present from curated keys are left untouched — we
    /// never fabricate the per-core readings a partially-mapped chip doesn't expose. Used to
    /// keep the panel complete on chips like M4 Max that read back only a subset of their keys.
    static func supplement(_ sample: TemperatureSample,
                           withHID hid: [(name: String, celsius: Double)],
                           categories: Set<SensorCategory>) -> TemperatureSample {
        var hidByCategory: [SensorCategory: [TempSensor]] = [:]
        for s in hid {
            let (category, label) = friendlyHID(s.name)
            guard categories.contains(category) else { continue }
            hidByCategory[category, default: []].append(
                TempSensor(rawName: s.name, name: label, celsius: s.celsius))
        }
        guard !hidByCategory.isEmpty else { return sample }

        var result = sample
        var groups = sample.groups
        for (category, sensors) in hidByCategory {
            let group = SensorGroup(category: category, sensors: sensors.sorted { $0.name < $1.name })
            groups.append(group)
            switch category {
            case .gpu:     if result.gpuCelsius == 0 { result.gpuCelsius = group.average }
            case .battery: if result.batteryCelsius == 0 { result.batteryCelsius = group.average }
            case .cpu:     if result.cpuCelsius == 0 { result.cpuCelsius = group.average; result.cpuMaxCelsius = group.maximum }
            default:       break
            }
        }
        // Keep groups in canonical category order so the panel layout stays stable.
        result.groups = SensorCategory.allCases.compactMap { cat in groups.first { $0.category == cat } }
        return result
    }

    /// Builds a TemperatureSample from the HID sensor set, grouping by classified category.
    static func buildSample(fromHID hid: [(name: String, celsius: Double)]) -> TemperatureSample {
        var byCategory: [SensorCategory: [TempSensor]] = [:]
        for s in hid {
            let (category, label) = friendlyHID(s.name)
            byCategory[category, default: []].append(
                TempSensor(rawName: s.name, name: label, celsius: s.celsius))
        }
        var result = TemperatureSample()
        var groups: [SensorGroup] = []
        for category in SensorCategory.allCases {
            guard let sensors = byCategory[category], !sensors.isEmpty else { continue }
            let group = SensorGroup(category: category, sensors: sensors.sorted { $0.name < $1.name })
            groups.append(group)
            switch category {
            case .cpu:     result.cpuCelsius = group.average; result.cpuMaxCelsius = group.maximum
            case .gpu:     result.gpuCelsius = group.average
            case .battery: result.batteryCelsius = group.average
            default:       break
            }
        }
        result.groups = groups
        return result
    }

    /// Classifies a raw HID sensor name into a category + a cleaned display label.
    /// Most Apple Silicon sensors are SoC die/thermal points (tdie/tdev/TP/tcal) → CPU/SoC.
    static func friendlyHID(_ raw: String) -> (category: SensorCategory, label: String) {
        let n = raw.lowercased()
        let label = raw.replacingOccurrences(of: "PMU ", with: "")
        if n.contains("battery") || n.contains("gas gauge") { return (.battery, "Battery") }
        if n.contains("nand") || n.contains("ssd") || n.contains("flash") { return (.memory, label) }
        if n.contains("gpu") { return (.gpu, label) }
        if n.contains("dram") || n.contains("ddr") { return (.memory, label) }
        return (.cpu, label)   // tdie / tdev / TP* / tcal — SoC die / CPU complex
    }
}
