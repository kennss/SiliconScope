//
//  File:      SensorCatalog.swift
//  Created:   2026-06-19
//  Updated:   2026-06-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Curated per-generation SMC temperature-key tables for Apple Silicon (M1–M5).
//             Apple's SMC FourCC keys are near-arbitrary and change every generation, so the
//             only way to get friendly per-unit names ("P-Core 1", "GPU 3", "Memory 2") is a
//             hand-maintained key->name map per chip generation, read directly (not scanned).
//             TemperatureSampler prefers this; it falls back to HID, then an SMC scan.
//  Notes:     Key tables adapted from exelban/stats (Modules/Sensors/values.swift), MIT
//             License. Variants (Pro/Max/Ultra) need no special-casing: keys that don't
//             exist on a given die simply don't read back and are skipped. Names are kept
//             short for the compact dropdown; the SensorCategory groups them.
//
import Foundation

public enum AppleSiliconGen: Sendable {
    case m1, m2, m3, m4, m5, unknown
}

public struct CuratedSensor: Sendable {
    public let key: String
    public let name: String
    public let category: SensorCategory
}

public enum SensorCatalog {
    /// Detects the Apple Silicon generation from the CPU brand string ("Apple M1 Max" -> .m1).
    public static func detectGeneration() -> AppleSiliconGen {
        let brand = brandString()
        guard let r = brand.range(of: "Apple M"),
              let digit = brand[r.upperBound...].first, let n = Int(String(digit)) else { return .unknown }
        switch n {
        case 1: return .m1
        case 2: return .m2
        case 3: return .m3
        case 4: return .m4
        case 5: return .m5
        default: return .unknown
        }
    }

    /// Curated (key, name, category) entries for a generation, in display order.
    public static func curated(for gen: AppleSiliconGen) -> [CuratedSensor] {
        switch gen {
        case .m1:      return m1
        case .m2:      return m2
        case .m3:      return m3
        case .m4:      return m4
        case .m5:      return m5
        case .unknown: return []
        }
    }

    // MARK: - Tables (adapted from exelban/stats, MIT)

    private static func cpu(_ pairs: [(String, String)]) -> [CuratedSensor] {
        pairs.map { CuratedSensor(key: $0.0, name: $0.1, category: .cpu) }
    }
    private static func gpu(_ pairs: [(String, String)]) -> [CuratedSensor] {
        pairs.map { CuratedSensor(key: $0.0, name: $0.1, category: .gpu) }
    }
    private static func mem(_ pairs: [(String, String)]) -> [CuratedSensor] {
        pairs.map { CuratedSensor(key: $0.0, name: $0.1, category: .memory) }
    }

    private static let m1: [CuratedSensor] =
        cpu([("Tp09", "E-Core 1"), ("Tp0T", "E-Core 2"),
             ("Tp01", "P-Core 1"), ("Tp05", "P-Core 2"), ("Tp0D", "P-Core 3"), ("Tp0H", "P-Core 4"),
             ("Tp0L", "P-Core 5"), ("Tp0P", "P-Core 6"), ("Tp0X", "P-Core 7"), ("Tp0b", "P-Core 8")]) +
        gpu([("Tg05", "GPU 1"), ("Tg0D", "GPU 2"), ("Tg0L", "GPU 3"), ("Tg0T", "GPU 4")]) +
        mem([("Tm02", "Memory 1"), ("Tm06", "Memory 2"), ("Tm08", "Memory 3"), ("Tm09", "Memory 4")])

    private static let m2: [CuratedSensor] =
        cpu([("Tp1h", "E-Core 1"), ("Tp1t", "E-Core 2"), ("Tp1p", "E-Core 3"), ("Tp1l", "E-Core 4"),
             ("Tp01", "P-Core 1"), ("Tp05", "P-Core 2"), ("Tp09", "P-Core 3"), ("Tp0D", "P-Core 4"),
             ("Tp0X", "P-Core 5"), ("Tp0b", "P-Core 6"), ("Tp0f", "P-Core 7"), ("Tp0j", "P-Core 8")]) +
        gpu([("Tg0f", "GPU 1"), ("Tg0j", "GPU 2")])

    private static let m3: [CuratedSensor] =
        cpu([("Te05", "E-Core 1"), ("Te0L", "E-Core 2"), ("Te0P", "E-Core 3"), ("Te0S", "E-Core 4"),
             ("Tf04", "P-Core 1"), ("Tf09", "P-Core 2"), ("Tf0A", "P-Core 3"), ("Tf0B", "P-Core 4"),
             ("Tf0D", "P-Core 5"), ("Tf0E", "P-Core 6"), ("Tf44", "P-Core 7"), ("Tf49", "P-Core 8"),
             ("Tf4A", "P-Core 9"), ("Tf4B", "P-Core 10"), ("Tf4D", "P-Core 11"), ("Tf4E", "P-Core 12")]) +
        gpu([("Tf14", "GPU 1"), ("Tf18", "GPU 2"), ("Tf19", "GPU 3"), ("Tf1A", "GPU 4"),
             ("Tf24", "GPU 5"), ("Tf28", "GPU 6"), ("Tf29", "GPU 7"), ("Tf2A", "GPU 8")])

    private static let m4: [CuratedSensor] =
        cpu([("Te05", "E-Core 1"), ("Te0S", "E-Core 2"), ("Te09", "E-Core 3"), ("Te0H", "E-Core 4"),
             ("Tp01", "P-Core 1"), ("Tp05", "P-Core 2"), ("Tp09", "P-Core 3"), ("Tp0D", "P-Core 4"),
             ("Tp0V", "P-Core 5"), ("Tp0Y", "P-Core 6"), ("Tp0b", "P-Core 7"), ("Tp0e", "P-Core 8")]) +
        gpu([("Tg0K", "GPU 3"), ("Tg0L", "GPU 4"), ("Tg0d", "GPU 5"),
             ("Tg0e", "GPU 6"), ("Tg0j", "GPU 7"), ("Tg0k", "GPU 8")]) +
        mem([("Tm0p", "Memory 1"), ("Tm1p", "Memory 2"), ("Tm2p", "Memory 3")])

    private static let m5: [CuratedSensor] =
        cpu([("Tp00", "Super 1"), ("Tp04", "Super 2"), ("Tp08", "Super 3"),
             ("Tp0C", "Super 4"), ("Tp0G", "Super 5"), ("Tp0K", "Super 6"),
             ("Tp0O", "P-Core 1"), ("Tp0R", "P-Core 2"), ("Tp0U", "P-Core 3"), ("Tp0X", "P-Core 4"),
             ("Tp0a", "P-Core 5"), ("Tp0d", "P-Core 6"), ("Tp0g", "P-Core 7"), ("Tp0j", "P-Core 8"),
             ("Tp0m", "P-Core 9"), ("Tp0p", "P-Core 10"), ("Tp0u", "P-Core 11"), ("Tp0y", "P-Core 12")]) +
        gpu([("Tg0U", "GPU 1"), ("Tg0X", "GPU 2"), ("Tg0d", "GPU 3"), ("Tg0g", "GPU 4"),
             ("Tg0j", "GPU 5"), ("Tg1Y", "GPU 6"), ("Tg1c", "GPU 7"), ("Tg1g", "GPU 8")])

    /// CPU brand string via sysctl (e.g. "Apple M1 Max").
    private static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
