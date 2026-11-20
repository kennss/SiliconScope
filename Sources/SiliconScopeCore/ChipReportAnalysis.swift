//
//  File:      ChipReportAnalysis.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The arithmetic of `sscope-cli --chip-report`: how much each SMC temperature key rose
//             under each standard load, and how the bandwidth SiliconScope read compares with what
//             a GPU kernel timed itself moving. Pure functions, so the report's numbers are tested.
//  Notes:     The procedure these numbers come from (idle, E-cores only, every core, GPU only, with
//             cool-downs between, then a memory-streaming kernel against the bandwidth reading)
//             follows the one @SpencerCurtis built by hand for the M3 Ultra (#93).
//             A key that a phase did not read stays nil for that phase — never 0 °C of rise.
//
import Foundation

public enum ChipReportAnalysis {

    /// One SMC key across the phases.
    public struct SensorRise: Equatable, Sendable {
        public let key: String
        /// In the curated table for this chip's generation.
        public let curated: Bool
        public let idleCelsius: Double
        /// Rise over idle for each load phase, in the order given; nil where that phase did not
        /// read the key.
        public let rises: [Double?]
    }

    /// Rise over idle for every key idle read, sorted by key.
    public static func sensorRises(idle: [String: Double],
                                   loads: [(label: String, readings: [String: Double])],
                                   curated: Set<String>) -> [SensorRise] {
        idle.keys.sorted().map { key in
            let base = idle[key]!
            return SensorRise(key: key, curated: curated.contains(key), idleCelsius: base,
                              rises: loads.map { load in load.readings[key].map { $0 - base } })
        }
    }

    /// The rises as a fixed-width table. "*" marks a key present on the chip but NOT in the
    /// curated table, as `--sensors-all` marks it.
    public static func sensorTable(_ rows: [SensorRise], loadLabels: [String]) -> String {
        var lines = ["key   cur   idle " + loadLabels.map { pad($0, 8) }.joined()]
        for r in rows {
            let rises = r.rises.map { pad($0.map { String(format: "%+.1f", $0) } ?? "—", 8) }.joined()
            lines.append(String(format: "%@  %@  %5.1f ", pad(r.key, 4, left: true) as NSString,
                                r.curated ? " " : "*", r.idleCelsius) + rises)
        }
        return lines.joined(separator: "\n")
    }

    /// What a memory-streaming GPU kernel timed itself moving, beside what SiliconScope read while
    /// it ran. `readings` are the bandwidth samples taken during the run.
    public static func bandwidthCheck(kernelGBs: Double?, readings: [BandwidthSample]) -> String {
        let kernel = kernelGBs.map { String(format: "%.1f GB/s", $0) } ?? "— (the kernel did not run)"
        let numbers = readings.compactMap { $0.belowGBs == nil ? $0.totalGBs : nil }
        let read: String
        if !numbers.isEmpty {
            let mean = numbers.reduce(0, +) / Double(numbers.count)
            let each = numbers.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            read = String(format: "%.1f GB/s (mean of %d: %@)", mean, numbers.count, each)
        } else if let bound = readings.compactMap(\.belowGBs).max() {
            read = String(format: "< %.0f GB/s (below the histogram's resolution)", bound)
        } else {
            read = "— (no bandwidth reading)"
        }
        var lines = ["GPU kernel, timed by the GPU (read + write): \(kernel)",
                     "SiliconScope total while it ran:              \(read)"]
        if let k = kernelGBs, k > 0, !numbers.isEmpty {
            let mean = numbers.reduce(0, +) / Double(numbers.count)
            lines.append(String(format: "SiliconScope / kernel: %.2f", mean / k))
        }
        if let split = readings.first?.hasRequestorSplit, !split {
            lines.append("This chip reports only a total; per-requestor lanes are not readable.")
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - s.count))
        return left ? s + fill : fill + s
    }
}
