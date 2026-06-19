//
//  File:      HIDSensorReader.swift
//  Created:   2026-06-19
//  Updated:   2026-06-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Swift wrapper over the C helper ktopCopyTemperatureSensors() (CIOReport),
//             which reads Apple Silicon temperature sensors sudolessly via the private
//             IOHIDEventSystem API (PrimaryUsagePage 0xff00 / usage 5). This is the rich
//             per-unit sensor source (per-core / GPU / memory / battery) that SMC does not
//             expose on Apple Silicon — the same source iStat uses for its SENSORS panel.
//  Notes:     Returns raw HID "Product" names (e.g. "pACC MTR Temp Sensor1"); friendly
//             grouping/labelling happens in TemperatureSampler. Values are °C.
//             Adapted approach from NeoAsitop (op06072/NeoAsitop), MIT License.
//
import Foundation
import CIOReport

public enum HIDSensorReader {
    /// One sudoless snapshot of the named Apple Silicon temperature sensors.
    /// Empty on non-Apple-Silicon or if the private API is unavailable.
    public static func read() -> [(name: String, celsius: Double)] {
        guard let cf = ktopCopyTemperatureSensors() else { return [] }
        let dict = cf.takeRetainedValue() as NSDictionary
        var out: [(name: String, celsius: Double)] = []
        for case let (key as String, value) in dict {
            guard let celsius = (value as? NSNumber)?.doubleValue else { continue }
            out.append((name: key, celsius: celsius))
        }
        return out
    }
}
