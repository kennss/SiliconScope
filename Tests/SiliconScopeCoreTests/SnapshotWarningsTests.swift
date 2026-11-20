//
//  File:      SnapshotWarningsTests.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in which memory states raise the banner: the kernel's critical level does, its
//             warning level does not — that one is a state, shown as colour.
//  Notes:     Swapping (sustained swap-out, #88) is added by the dashboard from the monitor's
//             verdict; it is not a snapshot-level warning and is covered by MetricsEngine tests.
//
import XCTest
@testable import SiliconScopeCore

final class SnapshotWarningsTests: XCTestCase {

    private func snapshot(_ pressure: MemorySample.Pressure) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.memory.pressure = pressure
        return s
    }

    func testKernelWarningIsAStateNotABanner() {
        XCTAssertTrue(snapshot(.warning).warnings.isEmpty)
        XCTAssertTrue(snapshot(.normal).warnings.isEmpty)
    }

    func testKernelCriticalRaisesTheBanner() {
        let w = snapshot(.critical).warnings
        XCTAssertEqual(w.map(\.message), ["Memory pressure: critical"])
        XCTAssertEqual(w.first?.level, .critical)
    }
}
