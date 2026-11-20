//
//  File:      BandwidthSplitTests.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in that a chip which reads only a total (M3 Max/Ultra's aggregate histogram,
//             A18's DRAM BW, a floor bound) never reports its per-requestor lanes as zeros.
//  Notes:     The Ultra numbers are @SpencerCurtis's from #93: total 737 GB/s with every lane 0,
//             which read as "the GPU at 100 % moved no memory".
//
import XCTest
@testable import SiliconScopeCore

final class BandwidthSplitTests: XCTestCase {

    private func totalOnly(_ gbs: Double) -> BandwidthSample {
        var b = BandwidthSample(); b.measuredTotalGBs = gbs; b.isEstimated = true
        return b
    }

    // MARK: - The flag

    func testOnlyATotalMeansNoSplit() {
        XCTAssertFalse(totalOnly(737).hasRequestorSplit)
        var floor = BandwidthSample(); floor.belowGBs = 128
        XCTAssertFalse(floor.hasRequestorSplit)
        var lanes = BandwidthSample(); lanes.cpuGBs = 6; lanes.gpuGBs = 1; lanes.otherGBs = 2
        XCTAssertTrue(lanes.hasRequestorSplit)
    }

    /// The total stays a reading; only the lanes become unknown.
    func testLanesReadAsUnknownNotZero() {
        let b = totalOnly(737)
        XCTAssertEqual(b.laneText(b.gpuGBs), "—")
        XCTAssertEqual(b.mediaText, "—")
        XCTAssertEqual(b.totalText, "737 GB/s")
        var lanes = BandwidthSample(); lanes.gpuGBs = 278
        XCTAssertEqual(lanes.laneText(lanes.gpuGBs), "278 GB/s")
        XCTAssertEqual(lanes.mediaText, "0.0 GB/s", "a split chip's zero is a measured zero")
    }

    // MARK: - What consumes the lanes

    func testMediaHistoryHasAGapNotAZero() {
        var s = SystemSnapshot(); s.bandwidth = totalOnly(737)
        var h = MetricsEngine.History()
        h.push(s)
        XCTAssertTrue(h.media.last?.isNaN ?? false)
        XCTAssertEqual(h.bandwidth.last, 737, "the total is still charted")
    }

    /// The media latch is not walked to "idle" by lanes nobody measured.
    func testMediaActivityIsLeftAloneWithoutASplit() {
        var on = SystemSnapshot(); on.bandwidth.mediaGBs = 2
        var activity = EngineActivity()
        for _ in 0..<4 { activity.update(on) }
        XCTAssertTrue(activity.media)
        var total = SystemSnapshot(); total.bandwidth = totalOnly(737)
        for _ in 0..<10 { activity.update(total) }
        XCTAssertTrue(activity.media, "unmeasured lanes must not count as the engine stopping")
        XCTAssertFalse(EngineActivity(instant: total).media)
    }

    func testMediaPeakIgnoresUnmeasuredLanes() {
        let e = MetricsEngine(topology: nil)
        var s = SystemSnapshot(); s.bandwidth.mediaGBs = 5
        e.ingest(s, dt: 1)
        let peak = e.mediaPeakGBs
        var total = SystemSnapshot(); total.bandwidth = totalOnly(737)
        for _ in 0..<50 { e.ingest(total, dt: 1) }
        XCTAssertEqual(e.mediaPeakGBs, peak, "a peak decays only on readings, not on lanes never read")
    }
}
