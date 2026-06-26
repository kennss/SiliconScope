//
//  File:      TemperatureSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
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
