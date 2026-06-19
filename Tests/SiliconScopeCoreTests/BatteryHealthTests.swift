//
//  File:      BatteryHealthTests.swift
//  Created:   2026-06-20
//  Updated:   2026-06-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pure tests for battery health % (full-charge / design capacity, clamped) and
//             the derived condition string. Capacities come from AppleSmartBattery at
//             runtime; the formula is extracted so it can be pinned without hardware.
//
import XCTest
@testable import SiliconScopeCore

final class BatteryHealthTests: XCTestCase {

    func testHealthFromCapacities() {
        // Real M1 Max values: NominalChargeCapacity 8166 / DesignCapacity 8694 ≈ 93.9%.
        XCTAssertEqual(BatterySampler.healthPercent(maxCapacity: 8166, designCapacity: 8694),
                       93.9, accuracy: 0.1)
    }

    func testHealthClampsAt100() {
        // A fresh battery can report full-charge slightly above design.
        XCTAssertEqual(BatterySampler.healthPercent(maxCapacity: 9000, designCapacity: 8000), 100)
    }

    func testHealthZeroWhenCapacitiesUnknown() {
        XCTAssertEqual(BatterySampler.healthPercent(maxCapacity: 0, designCapacity: 8694), 0)
        XCTAssertEqual(BatterySampler.healthPercent(maxCapacity: 8000, designCapacity: 0), 0)
    }

    func testConditionThresholds() {
        XCTAssertEqual(BatterySampler.condition(healthPercent: 94, permanentFailure: false), "Normal")
        XCTAssertEqual(BatterySampler.condition(healthPercent: 80, permanentFailure: false), "Normal")
        XCTAssertEqual(BatterySampler.condition(healthPercent: 79, permanentFailure: false),
                       "Service Recommended")
        // A permanent failure flag forces Service Recommended even at high health.
        XCTAssertEqual(BatterySampler.condition(healthPercent: 95, permanentFailure: true),
                       "Service Recommended")
    }
}
