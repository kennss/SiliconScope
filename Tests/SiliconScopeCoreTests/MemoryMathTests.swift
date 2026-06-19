//
//  File:      MemoryMathTests.swift
//  Created:   2026-06-20
//  Updated:   2026-06-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for the pure memory math: MemorySample fractions/used/free (with
//             the underflow + divide-by-zero guards) and MemoryBudget.estimate/fits — the
//             "what model fits" logic, which is derived from a sample with no syscalls.
//  Notes:     gb is 1024^3 in both types, so `gb(n)` bytes == n GB exactly in assertions.
//
import XCTest
@testable import SiliconScopeCore

final class MemoryMathTests: XCTestCase {

    private func gb(_ n: Double) -> UInt64 { UInt64(n * 1024 * 1024 * 1024) }

    // MARK: - MemorySample

    func testUsedFreeAndFractions() {
        var m = MemorySample()
        m.totalBytes = gb(16)
        m.wiredBytes = gb(4); m.activeBytes = gb(4); m.compressedBytes = gb(0)
        XCTAssertEqual(m.usedBytes, gb(8))
        XCTAssertEqual(m.freeBytes, gb(8))
        XCTAssertEqual(m.usedFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.usedPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(m.wiredFraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.freeFraction, 0.5, accuracy: 1e-9)
    }

    func testFreeBytesUnderflowGuard() {
        // used > total (can happen with compressed accounting) must not underflow UInt64.
        var m = MemorySample()
        m.totalBytes = gb(8)
        m.wiredBytes = gb(6); m.activeBytes = gb(6)
        XCTAssertEqual(m.freeBytes, 0)
        XCTAssertEqual(m.freeFraction, 0, accuracy: 1e-9)
    }

    func testZeroTotalNeverDividesByZero() {
        let m = MemorySample()           // totalBytes 0
        XCTAssertEqual(m.usedFraction, 0)
        XCTAssertEqual(m.wiredFraction, 0)
        XCTAssertEqual(m.freeFraction, 0)
    }

    // MARK: - MemoryBudget.estimate

    func testHeadroomAndOkRisk() {
        var m = MemorySample()
        m.totalBytes = gb(64); m.wiredBytes = gb(16); m.activeBytes = gb(16)   // used 32
        let b = MemoryBudget.estimate(memory: m)
        // reserved = max(3, 10% of 64 = 6.4) = 6.4 → headroom = 64 - 32 - 6.4 = 25.6
        XCTAssertEqual(b.headroomNowGB, 25.6, accuracy: 0.05)
        XCTAssertEqual(b.risk, .ok)
        XCTAssertEqual(b.loadableBytes, b.headroomNowBytes)   // no runtime RSS
    }

    func testReserveFloorAppliesOnSmallMachines() {
        var m = MemorySample()
        m.totalBytes = gb(8); m.wiredBytes = gb(1)            // used 1, 10% = 0.8 < 3 floor
        let b = MemoryBudget.estimate(memory: m)
        XCTAssertEqual(b.headroomNowGB, 4.0, accuracy: 0.05)  // 8 - 1 - 3(floor)
    }

    func testTightWhenNoHeadroom() {
        var m = MemorySample()
        m.totalBytes = gb(16); m.wiredBytes = gb(15)          // used 15, reserved 3 → headroom 0
        XCTAssertEqual(MemoryBudget.estimate(memory: m).risk, .tight)
    }

    func testCriticalPressureIsSwapping() {
        var m = MemorySample()
        m.totalBytes = gb(64); m.wiredBytes = gb(8)
        m.pressure = .critical
        XCTAssertEqual(MemoryBudget.estimate(memory: m).risk, .swapping)
    }

    func testActiveRuntimeRSSLiftsLoadableAboveHeadroom() {
        var m = MemorySample()
        m.totalBytes = gb(64); m.wiredBytes = gb(16); m.activeBytes = gb(16)
        let b = MemoryBudget.estimate(memory: m, activeRuntimeRSS: gb(10))
        XCTAssertEqual(b.loadableBytes, b.headroomNowBytes + gb(10))
        XCTAssertGreaterThan(b.loadableBytes, b.headroomNowBytes)
    }

    // MARK: - MemoryBudget.fits

    func testFitsIsOrderedByQuantAndPositive() {
        var m = MemorySample()
        m.totalBytes = gb(64); m.wiredBytes = gb(16); m.activeBytes = gb(16)
        let fits = MemoryBudget.estimate(memory: m).fitsNow
        XCTAssertEqual(fits.map(\.quant), ["Q4_K_M", "Q8_0", "F16"])
        // Lighter quant ⇒ more params fit.
        XCTAssertGreaterThan(fits[0].maxParamsBillions, fits[1].maxParamsBillions)
        XCTAssertGreaterThan(fits[1].maxParamsBillions, fits[2].maxParamsBillions)
        XCTAssertGreaterThan(fits[2].maxParamsBillions, 0)
        XCTAssertGreaterThan(fits[0].maxParamsBillions, 30)   // ~43B on 25.6 GB headroom
    }

    func testFitsZeroBudgetIsAllZero() {
        var m = MemorySample()
        m.totalBytes = gb(8); m.wiredBytes = gb(6)            // headroom 0 after 3 GB floor
        for fit in MemoryBudget.estimate(memory: m).fitsNow {
            XCTAssertEqual(fit.maxParamsBillions, 0, accuracy: 1e-9)
        }
    }
}
