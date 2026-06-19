//
//  File:      BottleneckTests.swift
//  Created:   2026-06-20
//  Updated:   2026-06-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for the hero classifier (Bottleneck.classify) and the per-chip
//             bandwidth-ceiling table. Both are pure value logic, so fixed inputs pin the
//             precedence (memory > thermal > workload) and the threshold tuning.
//  Notes:     No hardware: classify takes explicit smoothed inputs; the ceiling table is a
//             pure brand-string → GB/s lookup with pCore disambiguation for Max bins.
//
import XCTest
@testable import SiliconScopeCore

final class BottleneckTests: XCTestCase {

    // MARK: - Precedence: memory > thermal > everything

    func testMemoryPressureWinsOverEverything() {
        // Even with the GPU pegged and bandwidth maxed and throttling, critical memory wins.
        XCTAssertEqual(Bottleneck.classify(memoryCritical: true, gpuUsage: 1.0,
                                           bandwidthGBs: 400, achievableGBs: 400, throttling: true),
                       .memoryPressured)
    }

    func testThermalWinsOverWorkloadProfile() {
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 1.0,
                                           bandwidthGBs: 400, achievableGBs: 400, throttling: true),
                       .thermalThrottled)
    }

    // MARK: - Workload profile

    func testIdleBelowGpuFloor() {
        // Resting compositor GPU (<30%) is idle, regardless of bandwidth noise.
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.20,
                                           bandwidthGBs: 380, achievableGBs: 400, throttling: false),
                       .idle)
    }

    func testBandwidthBoundNearCeiling() {
        // GPU busy + bandwidth ≥ 85% of the achievable peak ⇒ bandwidth-bound (LLM decode).
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.95,
                                           bandwidthGBs: 360, achievableGBs: 400, throttling: false),
                       .bandwidthBound)
    }

    func testComputeBoundWhenGpuPeggedButBandwidthHasHeadroom() {
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.95,
                                           bandwidthGBs: 200, achievableGBs: 400, throttling: false),
                       .computeBound)
    }

    func testGpuActiveWhenBusyButNeitherLimiterDominates() {
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.50,
                                           bandwidthGBs: 200, achievableGBs: 400, throttling: false),
                       .gpuActive)
    }

    func testBandwidthBoundThresholdIsExactly85Percent() {
        // 0.85 is bandwidth-bound; just under is not.
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.95,
                                           bandwidthGBs: 340, achievableGBs: 400, throttling: false),
                       .bandwidthBound)                          // 340/400 = 0.85
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.95,
                                           bandwidthGBs: 336, achievableGBs: 400, throttling: false),
                       .computeBound)                            // 336/400 = 0.84, GPU ≥ 0.90
    }

    func testZeroAchievablePeakNeverDividesByZero() {
        // Before any peak is observed, achievableGBs is 0 → never bandwidth-bound.
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.95,
                                           bandwidthGBs: 999, achievableGBs: 0, throttling: false),
                       .computeBound)
        XCTAssertEqual(Bottleneck.classify(memoryCritical: false, gpuUsage: 0.50,
                                           bandwidthGBs: 999, achievableGBs: 0, throttling: false),
                       .gpuActive)
    }

    func testIsProblemFlag() {
        XCTAssertTrue(Bottleneck.thermalThrottled.isProblem)
        XCTAssertTrue(Bottleneck.memoryPressured.isProblem)
        XCTAssertFalse(Bottleneck.bandwidthBound.isProblem)
        XCTAssertFalse(Bottleneck.idle.isProblem)
    }

    // MARK: - Per-chip bandwidth ceiling table

    func testCeilingBaseChips() {
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M1", pCoreCount: 4), 68)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M2", pCoreCount: 4), 100)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M3", pCoreCount: 4), 100)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M4", pCoreCount: 4), 120)
    }

    func testCeilingProAndUltra() {
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M1 Pro", pCoreCount: 8), 200)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M1 Ultra", pCoreCount: 16), 800)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M2 Ultra", pCoreCount: 16), 800)
    }

    func testCeilingMaxBinsDisambiguatedByPCoreCount() {
        // M3 Max: full (12 P) = 400, binned (10 P) = 300.
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M3 Max", pCoreCount: 12), 400)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M3 Max", pCoreCount: 10), 300)
        // M4 Max: full = 546, binned = 410.
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M4 Max", pCoreCount: 12), 546)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M4 Max", pCoreCount: 10), 410)
    }

    func testCeilingUnknownChipIsZero() {
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Apple M9 Ultra", pCoreCount: 99), 0)
        XCTAssertEqual(Bottleneck.bandwidthCeilingGBs(chipName: "Intel Core i9", pCoreCount: 8), 0)
    }
}
