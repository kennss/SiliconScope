//
//  File:      TemperatureSample.swift
//  Created:   2026-06-08
//  Updated:   2026-09-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Temperature readings grouped into user-friendly categories (CPU, GPU,
//             Memory, Battery, Other) with CPU and Battery surfaced as representatives.
//  Notes:     Sourced from SMC keys: Tp*=CPU cores, Tg*=GPU, Tm*=Memory, TB*=Battery
//             (well-established Apple Silicon prefixes). Uncategorized keys fall under
//             Other. cpuCelsius is the average of CPU-core sensors.
//
import Foundation

public enum SensorCategory: String, Sendable, CaseIterable, Codable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case other = "Other"

    /// The coldest reading that can be a real measurement of this thing, in °C.
    ///
    /// ⚠️ A powered die is warmer than the room it sits in — every verified idle reading we have
    /// is 37 °C or above (M4 39, M2 Max 42, M1 Max 54, M5 Max 63). So a CPU or GPU sensor reporting
    /// single digits is not a cold chip, it is not a temperature at all. On an M2 Max under
    /// macOS 26.6.2 the SMC intermittently serves a fixed six-value cycle — 5.3 / 6.0 / 6.7 / 7.4 /
    /// 8.4 and blanks — on the core keys, verified as coming from the SMC rather than from us by a
    /// second, unrelated reader seeing the identical values (#57). They sat just above the old
    /// blanket floor of 5 and were published as die temperatures.
    ///
    /// Other things genuinely do run cool — a battery at 31 °C, NAND at 26 °C, an ambient sensor at
    /// 27 °C — so the floor is per category rather than one number for everything.
    public var plausibleFloorCelsius: Double {
        switch self {
        case .cpu, .gpu:                   return 20
        case .memory, .battery, .other:    return 5
        }
    }
}

public struct TempSensor: Sendable, Equatable, Identifiable, Codable {
    public let rawName: String     // SMC key (unique id)
    public let name: String        // friendly label
    public let celsius: Double
    public var id: String { rawName }

    public init(rawName: String, name: String, celsius: Double) {
        self.rawName = rawName
        self.name = name
        self.celsius = celsius
    }
}

public struct SensorGroup: Sendable, Equatable, Identifiable, Codable {
    public let category: SensorCategory
    public let sensors: [TempSensor]
    public var id: String { category.rawValue }

    public init(category: SensorCategory, sensors: [TempSensor]) {
        self.category = category
        self.sensors = sensors
    }

    public var count: Int { sensors.count }
    public var average: Double {
        sensors.isEmpty ? 0 : sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
    }
    public var maximum: Double { sensors.map(\.celsius).max() ?? 0 }
}

public struct TemperatureSample: Sendable, Equatable, Codable {
    public var cpuCelsius: Double = 0       // average of CPU-core sensors
    public var cpuMaxCelsius: Double = 0
    public var gpuCelsius: Double = 0
    public var batteryCelsius: Double = 0
    public var groups: [SensorGroup] = []

    public init() {}

    public var hasCPU: Bool { cpuCelsius > 0 }
    public var hasGPU: Bool { gpuCelsius > 0 }
    public var hasBattery: Bool { batteryCelsius > 0 }
}
