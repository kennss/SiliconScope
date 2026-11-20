//
//  File:      ChipReportAnalysisTests.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the arithmetic of `sscope-cli --chip-report`: per-key temperature rises and
//             the bandwidth cross-check.
//  Notes:     Bandwidth figures are @SpencerCurtis's from #93 (M3 Ultra, macOS 27.2.1).
//
import XCTest
@testable import SiliconScopeCore

final class ChipReportAnalysisTests: XCTestCase {

    func testRisesAreOverIdleAndAMissingKeyStaysUnknown() {
        let rows = ChipReportAnalysis.sensorRises(
            idle: ["Tp01": 40, "Tg05": 38],
            loads: [("ecore", ["Tp01": 43, "Tg05": 38.5]),
                    ("gpu", ["Tg05": 60])],          // Tp01 not read in this phase
            curated: ["Tp01"])
        XCTAssertEqual(rows.map(\.key), ["Tg05", "Tp01"])
        let tp = rows[1]
        XCTAssertTrue(tp.curated)
        XCTAssertEqual(tp.rises[0] ?? .nan, 3, accuracy: 1e-9)
        XCTAssertNil(tp.rises[1], "a key a phase did not read is unknown, not 0 °C of rise")
        XCTAssertFalse(rows[0].curated)
        XCTAssertEqual(rows[0].rises[1] ?? .nan, 22, accuracy: 1e-9)
    }

    func testTableMarksUncuratedKeysAndUnknownRises() {
        let rows = ChipReportAnalysis.sensorRises(idle: ["Tf0D": 50], loads: [("gpu", [:])], curated: [])
        let table = ChipReportAnalysis.sensorTable(rows, loadLabels: ["gpu"])
        let line = table.split(separator: "\n")[1]
        XCTAssertTrue(line.hasPrefix("Tf0D  *"))
        XCTAssertTrue(line.hasSuffix("—"))
    }

    func testBandwidthCheckSetsTheReadingBesideTheKernel() {
        func total(_ g: Double) -> BandwidthSample { var b = BandwidthSample(); b.measuredTotalGBs = g; return b }
        let text = ChipReportAnalysis.bandwidthCheck(kernelGBs: 692,
                                                     readings: [total(737), total(729), total(722)])
        XCTAssertTrue(text.contains("692.0 GB/s"))
        XCTAssertTrue(text.contains("729.3 GB/s (mean of 3: 737, 729, 722)"))
        XCTAssertTrue(text.contains("SiliconScope / kernel: 1.05"))
        XCTAssertTrue(text.contains("only a total"))
    }

    /// An idle-floor reading is a bound, not a number to average.
    func testABoundIsReportedAsABound() {
        var floor = BandwidthSample(); floor.belowGBs = 128
        let text = ChipReportAnalysis.bandwidthCheck(kernelGBs: nil, readings: [floor])
        XCTAssertTrue(text.contains("< 128 GB/s"))
        XCTAssertFalse(text.contains("SiliconScope / kernel"))
    }
}
