//
//  File:      ThermalSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one thermal reading: OS thermal pressure plus fan
//             speeds. Thermal pressure is the primary throttle signal for sustained
//             AI workloads.
//  Notes:     pressure mirrors ProcessInfo.thermalState. fanRPMs is empty on fanless
//             Macs (e.g. MacBook Air) — check hasFans before display.
//
import Foundation

public struct ThermalSample: Sendable, Equatable, Codable {
    public enum Pressure: String, Sendable, Codable {
        case nominal, fair, serious, critical, unknown
    }

    public var pressure: Pressure = .nominal
    public var fanRPMs: [Double] = []

    public init() {}

    public var hasFans: Bool { !fanRPMs.isEmpty }
    public var maxFanRPM: Double { fanRPMs.max() ?? 0 }
    public var isThrottling: Bool { pressure == .serious || pressure == .critical }
}
