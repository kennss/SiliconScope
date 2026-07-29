//
//  File:      MetricsEngineTests.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks the behavior of MetricsEngine — the derivation extracted from
//             SiliconScopeMonitor so live and replay share identical logic. Verifies the
//             decaying-peak fold (+ floors), GPU-clock peak (no floor), history roll-to-60,
//             memory-rate deltas over dt (and first-frame/dt=0/reset = 0), and the throttle /
//             memory-risk verdicts. These are the parity guarantees the live↔replay split rests on.
//
import XCTest
@testable import SiliconScopeCore

final class MetricsEngineTests: XCTestCase {

    private func snap(bandwidth: Double = 0, media: Double = 0, ane: Double = 0,
                      gpuFreq: Double = 0, gpuUsage: Double = 0,
                      pageins: UInt64 = 0, swapouts: UInt64 = 0) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.bandwidth.cpuGBs = bandwidth      // totalGBs = sum of parts
        s.bandwidth.mediaGBs = media
        s.power.aneWatts = ane
        s.gpu.freqMHz = gpuFreq
        s.gpu.usage = gpuUsage
        s.memory.pageins = pageins
        s.memory.swapouts = swapouts
        return s
    }

    // Peaks adopt a new high instantly, then decay slowly (×0.999) but never below the floor.
    func testPeakFoldAndFloor() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(bandwidth: 200), dt: 1)
        XCTAssertEqual(e.bandwidthPeakGBs, 200, accuracy: 0.001)   // adopted
        e.ingest(snap(bandwidth: 0), dt: 1)
        XCTAssertEqual(e.bandwidthPeakGBs, 200 * 0.999, accuracy: 0.01)   // slow decay
        // Many low frames: never falls below the 40 GB/s floor.
        for _ in 0..<10_000 { e.ingest(snap(bandwidth: 0), dt: 1) }
        XCTAssertGreaterThanOrEqual(e.bandwidthPeakGBs, 40)
    }

    // GPU-clock peak has NO floor (unlike bandwidth/media/ANE) — it can decay toward 0.
    func testGpuClockPeakNoFloor() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(gpuFreq: 1000), dt: 1)
        XCTAssertEqual(e.gpuClockPeakMHz, 1000, accuracy: 0.001)
        e.ingest(snap(gpuFreq: 0), dt: 1)
        XCTAssertEqual(e.gpuClockPeakMHz, 999, accuracy: 0.01)
    }

    func testHistoryRollsTo60() {
        let e = MetricsEngine(topology: nil)
        for _ in 0..<70 { e.ingest(snap(gpuUsage: 0.5), dt: 1) }
        XCTAssertEqual(e.history.gpu.count, 60)
    }

    // First frame has no predecessor → rate 0; second computes delta / dt.
    func testMemoryRateDeltaOverDt() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(pageins: 100), dt: 1)
        XCTAssertEqual(e.memoryPageInRate, 0)                 // no previous frame
        e.ingest(snap(pageins: 300), dt: 2)
        XCTAssertEqual(e.memoryPageInRate, 100, accuracy: 0.001)   // (300-100)/2
    }

    func testMemoryRateZeroWhenDtZero() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(pageins: 100), dt: 1)
        e.ingest(snap(pageins: 999), dt: 0)
        XCTAssertEqual(e.memoryPageInRate, 0)
    }

    func testResetClearsRates() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(pageins: 100), dt: 1)
        e.ingest(snap(pageins: 300), dt: 1)
        XCTAssertGreaterThan(e.memoryPageInRate, 0)
        e.reset()
        // After reset the next frame is treated as the first again → rate 0.
        e.ingest(snap(pageins: 900), dt: 1)
        XCTAssertEqual(e.memoryPageInRate, 0)
    }

    // Throttle: GPU active + thermal pressure risen + clock held below 85% of peak.
    func testGpuThrottling() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(gpuFreq: 1000, gpuUsage: 0.5), dt: 1)   // sets peak 1000, not throttling
        XCTAssertFalse(e.gpuThrottling)

        // ⚠️ A clock below the peak under thermal pressure is NOT enough on its own — this fixture
        // used to assert that it was. Throttling is demand without response, so the snapshot has to
        // carry the demand too: a hot die and a GPU actually drawing power. Without them this is
        // indistinguishable from a machine cooling down, which is the false positive that put a red
        // border on both cards of an idle Mac.
        var hot = snap(gpuFreq: 500, gpuUsage: 0.5)           // 500 < 0.85*~999
        hot.thermal.pressure = .critical
        hot.temperature.gpuCelsius = 98
        hot.power.gpuWatts = 30
        e.ingest(hot, dt: 1)
        XCTAssertTrue(e.gpuThrottling)

        // The same clock and pressure on a cool, idle GPU: not throttling.
        var cool = snap(gpuFreq: 500, gpuUsage: 0.5)
        cool.thermal.pressure = .critical
        cool.temperature.gpuCelsius = 55
        cool.power.gpuWatts = 0.4
        e.ingest(cool, dt: 1)
        XCTAssertFalse(e.gpuThrottling)
    }

    // Active swap-out → memory risk escalates to .swapping.
    func testMemoryRiskSwapping() {
        let e = MetricsEngine(topology: nil)
        e.ingest(snap(swapouts: 0), dt: 1)
        e.ingest(snap(swapouts: 5000), dt: 1)                 // swapouts rising → rate > 0
        XCTAssertEqual(e.memoryRisk, .swapping)
    }
}
