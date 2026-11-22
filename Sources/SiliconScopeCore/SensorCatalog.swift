//
//  File:      SensorCatalog.swift
//  Created:   2026-06-19
//  Updated:   2026-11-22
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
//             Exception — M3 Ultra (#94, measured by @SpencerCurtis on Mac15,14): an Ultra is two
//             dies, and its second die's CPU sensors are separate keys (`Tf5x`/`Tf9x`, mirroring
//             the first die's `Tf0x`/`Tf4x`). A load macOS placed on the second die alone (IOReport's
//             per-core `DIE_1_` residency) raised them and left `Tf0x`/`Tf4x` flat. They
//             are added only when the brand string says Ultra, so an M3 Max, where nobody has
//             checked whether those keys exist or what they would read, is unchanged. On the
//             Ultra `x4` and `xE` read the same sensor (equal to 0.1 °C across 14 captures, idle
//             and loaded), so the `xE` keys are dropped there; that duplication is unverified on
//             M3 Max, which keeps both. The second die's keys are named "Die 2 CPU n", by die
//             and not core: which key is which core, and E vs P, are not known. Its GPU keys
//             are left out until a measurement separates them (a GPU load heats both dies).
//
import Foundation

public enum AppleSiliconGen: Sendable {
    case m1, m2, m3, m4, m5
    case a18   // A18 Pro — the MacBook Neo (Mac17,5). Recognized; curated SMC keys TBD (#12).
    case unknown
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
        if brand.contains("Apple A18") { return .a18 }   // MacBook Neo (A18 Pro)
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

    /// Whether this Mac's chip is an Ultra (two dies fused), from the brand string.
    public static let isUltra: Bool = brandString().contains("Ultra")

    /// Curated (key, name, category) entries for a generation, in display order.
    /// `ultra` adds what is measured for that generation's second die (only M3 so far, #94).
    public static func curated(for gen: AppleSiliconGen, ultra: Bool = isUltra) -> [CuratedSensor] {
        switch gen {
        case .m1:      return m1
        case .m2:      return m2
        case .m3:      return ultra ? m3Ultra : m3
        case .m4:      return m4
        case .m5:      return m5
        case .a18:     return []   // no curated SMC table yet — falls back to HID temps (#12)
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

    /// M3 Ultra (#94): the first die's table without the `xE` duplicates of `x4`, then the second die's CPU keys.
    private static let m3Ultra: [CuratedSensor] = {
        let duplicates: Set<String> = ["Tf0E", "Tf4E"]   // == Tf04 / Tf44 on the Ultra
        let dieOne = m3.filter { !duplicates.contains($0.key) }
        let dieTwoCPU = cpu([("Tf54", "Die 2 CPU 1"), ("Tf59", "Die 2 CPU 2"),
                             ("Tf5A", "Die 2 CPU 3"), ("Tf5B", "Die 2 CPU 4"),
                             ("Tf94", "Die 2 CPU 5"), ("Tf99", "Die 2 CPU 6"),
                             ("Tf9A", "Die 2 CPU 7"), ("Tf9B", "Die 2 CPU 8")])
        // CPU entries stay together: the second die's cores follow the first die's, before the GPU.
        return dieOne.filter { $0.category == .cpu } + dieTwoCPU + dieOne.filter { $0.category != .cpu }
    }()

    private static let m4: [CuratedSensor] =
        cpu([("Te05", "E-Core 1"), ("Te0S", "E-Core 2"), ("Te09", "E-Core 3"), ("Te0H", "E-Core 4"),
             ("Tp01", "P-Core 1"), ("Tp05", "P-Core 2"), ("Tp09", "P-Core 3"), ("Tp0D", "P-Core 4"),
             ("Tp0V", "P-Core 5"), ("Tp0Y", "P-Core 6"), ("Tp0b", "P-Core 7"), ("Tp0e", "P-Core 8")]) +
        gpu([("Tg0G", "GPU 1"), ("Tg0H", "GPU 2"),                    // base M4
             ("Tg1U", "GPU 1"), ("Tg1k", "GPU 2"),                    // M4 Pro/Max/Ultra (mutually exclusive w/ base)
             ("Tg0K", "GPU 3"), ("Tg0L", "GPU 4"), ("Tg0d", "GPU 5"),
             ("Tg0e", "GPU 6"), ("Tg0j", "GPU 7"), ("Tg0k", "GPU 8")]) +
        mem([("Tm0p", "Memory 1"), ("Tm1p", "Memory 2"), ("Tm2p", "Memory 3")])

    private static let m5: [CuratedSensor] =
        cpu([("Tp00", "Super 1"), ("Tp04", "Super 2"), ("Tp08", "Super 3"),
             ("Tp0C", "Super 4"), ("Tp0G", "Super 5"), ("Tp0K", "Super 6"),
             ("Tp0O", "P-Core 1"), ("Tp0R", "P-Core 2"), ("Tp0U", "P-Core 3"), ("Tp0X", "P-Core 4"),
             ("Tp0a", "P-Core 5"), ("Tp0d", "P-Core 6"), ("Tp0g", "P-Core 7"), ("Tp0j", "P-Core 8"),
             ("Tp0m", "P-Core 9"), ("Tp0p", "P-Core 10"), ("Tp0u", "P-Core 11"), ("Tp0y", "P-Core 12")]) +
        gpu([("Tg0U", "GPU 1"), ("Tg0X", "GPU 2"), ("Tg0d", "GPU 3"), ("Tg0g", "GPU 4"),
             ("Tg0j", "GPU 5"), ("Tg1Y", "GPU 6"), ("Tg1c", "GPU 7"), ("Tg1g", "GPU 8")]) +
        mem([("Tm0p", "Memory 1")])   // verified on M5 Max; Tm1p/Tm2p absent on this die

    /// CPU brand string via sysctl (e.g. "Apple M1 Max").
    private static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cBuffer: buffer)
    }
}
