//
//  File:      ANEActivityTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in measured Neural Engine activity — residency from SoC Stats › Cluster Power
//             States — and the ANE lane split out of "other" bandwidth.
//  Notes:     Residencies below are shaped like the M1 Max's while WhisperKit transcribed: ANE0 ACT
//             for the whole window, ANE1 (a channel a Max has but never activates) INACT throughout,
//             ANE DRAM traffic ~19 GB/s — at a moment when the ANE power counter had not moved in
//             minutes (macOS 27, #65).
//
import XCTest
@testable import SiliconScopeCore

final class ANEActivityTests: XCTestCase {

    // MARK: - Residency

    func testResidencyIsTheActiveShareOfTheSlice() {
        let a = ANESampler.activity([[("ACT", 30), ("INACT", 70)]])
        XCTAssertEqual(a?.activeFraction ?? -1, 0.30, accuracy: 1e-9)
    }

    /// ⚠️ A Max exposes ANE1 and never activates it. Averaging clusters would read a fully busy Max
    /// as 50 %; the busiest cluster is the engine's activity.
    func testTheBusiestClusterIsTheReading() {
        // Both channels declare ACT and INACT; ANE1's ACT residency is simply 0.
        let a = ANESampler.activity([[("ACT", 52_000_767), ("INACT", 0)], [("ACT", 0), ("INACT", 52_000_671)]])
        XCTAssertEqual(a?.activeFraction, 1.0)
        XCTAssertEqual(a?.clusters, [1.0, 0.0])
    }

    /// A shape it has not seen is unknown, not zero.
    func testAnUnfamiliarShapeIsNotAReading() {
        XCTAssertNil(ANESampler.activity([[("ON", 5), ("OFF", 5)]]))
        XCTAssertNil(ANESampler.activity([]))
    }

    // MARK: - What activity drives

    private func transcribing(powerKnown: Bool) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.ane = ANESample(activeFraction: 1.0, clusters: [1.0, 0])
        if !powerKnown { s.power.railWindowSeconds = 0 }
        return s
    }

    /// The report: an ANE-heavy transcription on macOS 27 read "ANE idle" because its watts were
    /// unknown. Measured residency must latch it active with no power at all.
    func testResidencyLatchesTheANEWhilePowerIsUnknown() {
        var activity = EngineActivity()
        for _ in 0..<4 { activity.update(transcribing(powerKnown: false)) }
        XCTAssertTrue(activity.ane)
        XCTAssertTrue(transcribing(powerKnown: false).aneBusy)
        XCTAssertEqual(transcribing(powerKnown: false).likelyAIEngine, "ANE (CoreML)")
    }

    func testAnIdleEngineLatchesOff() {
        var activity = EngineActivity()
        for _ in 0..<4 { activity.update(transcribing(powerKnown: false)) }
        var idle = SystemSnapshot()
        idle.ane = ANESample(activeFraction: 0, clusters: [0, 0])
        for _ in 0..<8 { activity.update(idle) }
        XCTAssertFalse(activity.ane)
    }

    /// Without the channel, behaviour is exactly what it was: live ANE power is the evidence.
    func testWithoutResidencyPowerStillDecides() {
        var s = SystemSnapshot()
        s.power.aneWatts = 3
        XCTAssertNil(s.ane)
        XCTAssertTrue(s.aneBusy)
    }

    func testTheHistoryKeepsAResidencySeriesWithGapsWhereUnmeasured() {
        var h = MetricsEngine.History()
        h.push(transcribing(powerKnown: true))
        h.push(transcribing(powerKnown: true), measured: [.memory])
        XCTAssertEqual(h.aneActive.first, 1.0)
        XCTAssertTrue(h.aneActive.last?.isNaN ?? false)
    }

    // MARK: - The ANE bandwidth lane

    /// ANE traffic used to fall through to "other" — WhisperKit's ~19 GB/s filed as
    /// display/storage/PCIe.
    func testANERequestorsAreTheirOwnLane() {
        XCTAssertEqual(BandwidthSampler.classify(requestor: "ANE0"), .ane)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 ANE1"), .ane)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("ANEL0"), .ane)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "ANS"), .other, "the storage controller is not the ANE")
    }

    /// A recording from before the split has its ANE traffic inside "other". It must decode with the
    /// lane ABSENT (not 0 — that would claim an idle ANE nobody measured) and the same total.
    func testAnOldRecordingHasNoANELaneAndTheSameTotal() throws {
        let json = #"{"cpuGBs":7,"gpuGBs":92,"mediaGBs":0,"otherGBs":27}"#
        let b = try JSONDecoder().decode(BandwidthSample.self, from: Data(json.utf8))
        XCTAssertNil(b.aneGBs)
        XCTAssertEqual(b.totalGBs, 126)
    }

    // MARK: - The wire

    func testRemoteMacsSendTheirANEActivityAndLane() throws {
        var s = transcribing(powerKnown: false)
        s.bandwidth.aneGBs = 19
        let topo = CPUTopology(chipName: "Apple M1 Max", eCoreCount: 2, pCoreCount: 8,
                               eFreqsMHz: [], pFreqsMHz: [], gpuFreqsMHz: [])
        let m = MachineMetrics.mac(snapshot: s, topology: topo, hostname: "h", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 0,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0)
        let (r, _) = try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m)).toDashboardSnapshot()
        XCTAssertEqual(r.ane?.activeFraction, 1.0)
        XCTAssertEqual(r.bandwidth.aneGBs, 19)
        XCTAssertTrue(r.aneBusy)
    }
}
