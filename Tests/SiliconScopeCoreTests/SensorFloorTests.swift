//
//  File:      SensorFloorTests.swift
//  Created:   2026-09-14
//  Updated:   2026-09-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the per-category plausibility floor that keeps a non-temperature from being
//             published as a die temperature (#57).
//  Notes:     The six values below are the ones an M2 Max under macOS 26.6.2 intermittently serves
//             on its core keys — measured, and confirmed to come from the SMC rather than from our
//             decode by a second unrelated reader seeing the identical numbers. They cluster just
//             above the old blanket floor of 5 °C, which is why they were published. Real idle die
//             readings from verified machines are in the other set: no overlap, and a wide margin.
//
import XCTest
@testable import SiliconScopeCore

final class SensorFloorTests: XCTestCase {

    /// Exactly what the SMC served on an M2 Max when the read failed.
    private let artefacts: [Double] = [5.3, 5.324_999_809_265_137, 6.0, 6.7,
                                       6.699_999_809_265_137, 7.4, 8.4, 8.425_000_190_734_863]

    /// Verified idle die readings: M4 base, M2 Max, M1 Max, M5 Max.
    private let realDieIdle: [Double] = [37.3, 39.2, 42.0, 45.1, 46.3, 54.8, 63.4, 67.7]

    func testNoArtefactSurvivesTheDieFloor() {
        for v in artefacts {
            XCTAssertFalse(v > SensorCategory.cpu.plausibleFloorCelsius,
                           "\(v) °C would be published as a CPU die temperature")
            XCTAssertFalse(v > SensorCategory.gpu.plausibleFloorCelsius,
                           "\(v) °C would be published as a GPU die temperature")
        }
    }

    func testEveryVerifiedDieReadingSurvives() {
        for v in realDieIdle {
            XCTAssertTrue(v > SensorCategory.cpu.plausibleFloorCelsius, "\(v) °C is a real reading")
        }
    }

    /// The floor has to sit in the gap, not against either edge — a number tuned to the artefacts
    /// would fail on the next variant of them.
    func testTheFloorSitsWithWideMarginOnBothSides() {
        let floor = SensorCategory.cpu.plausibleFloorCelsius
        XCTAssertGreaterThan(floor - (artefacts.max() ?? 0), 10,
                             "floor is too close to the artefacts it must reject")
        XCTAssertGreaterThan((realDieIdle.min() ?? 0) - floor, 10,
                             "floor is too close to the coldest real reading it must keep")
    }

    /// Things that genuinely run cool keep the low floor: a battery at 31 °C, NAND at 26 °C, an
    /// ambient sensor at 27 °C. Raising one number for everything would have hidden all of them.
    func testCoolThingsAreNotDieTemperatures() {
        for (category, reading) in [(SensorCategory.battery, 31.6),
                                    (.memory, 26.0),
                                    (.other, 27.9)] {
            XCTAssertTrue(reading > category.plausibleFloorCelsius,
                          "\(reading) °C is a real \(category.rawValue) reading")
        }
    }
}
