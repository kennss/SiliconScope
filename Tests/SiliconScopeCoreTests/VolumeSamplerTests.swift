//
//  File:      VolumeSamplerTests.swift
//  Created:   2026-08-07
//  Updated:   2026-08-07
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for VolumeInfo.usedFraction, pinning the [0, 1] clamp so a sparse
//             or network volume that reports freeBytes > totalBytes (or a negative freeBytes)
//             can never make the used fraction read negative or above 1.0.
//  Notes:     VolumeInfo.freeBytes is Int64 (unlike the UInt64 Disk path), so it can go negative;
//             the clamp therefore needs max(…, 0) in addition to min(…, totalBytes). Values here
//             are exact integer-rational Doubles, so plain XCTAssertEqual needs no accuracy.
//
import XCTest
@testable import SiliconScopeCore

final class VolumeSamplerTests: XCTestCase {

    func testFreeAboveTotalClampsToZero() {
        // Sparse/network volumes can report more free than total → used fraction must be 0, not -0.5.
        let v = VolumeInfo(name: "X", totalBytes: 1_000_000, freeBytes: 1_500_000, isLocal: false)
        XCTAssertEqual(v.usedFraction, 0.0)
    }

    func testNegativeFreeClampsToOne() {
        // A negative Int64 freeBytes must read as fully used (1.0), not 1.2.
        let v = VolumeInfo(name: "Y", totalBytes: 1_000_000, freeBytes: -200_000, isLocal: true)
        XCTAssertEqual(v.usedFraction, 1.0)
    }

    func testNormalInRangeUnchanged() {
        let v = VolumeInfo(name: "Z", totalBytes: 1_000_000, freeBytes: 250_000, isLocal: true)
        XCTAssertEqual(v.usedFraction, 0.75)
    }

    func testZeroTotalGuardUnchanged() {
        let v = VolumeInfo(name: "empty", totalBytes: 0, freeBytes: 0, isLocal: true)
        XCTAssertEqual(v.usedFraction, 0.0)
    }
}
