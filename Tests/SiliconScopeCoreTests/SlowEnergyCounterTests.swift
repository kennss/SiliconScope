//
//  File:      SlowEnergyCounterTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in everything around EnergyRefreshTracker that makes #65's fix hold end to end:
//             which channels feed it, how unknown power reaches history, recordings and the wire.
//  Notes:     EnergyRefreshTrackerTests covers the tracker itself. These cover the joints, which is
//             where a correct tracker would still be undone — one extra channel in its input, or one
//             consumer that reads the placeholder zeros as a reading.
//
import XCTest
@testable import SiliconScopeCore

final class SlowEnergyCounterTests: XCTestCase {

    // MARK: - What feeds the tracker

    /// ⚠️ The regression that would bring #65 back unnoticed. "GPU Energy" is a different unit and
    /// on macOS 27 it keeps moving on every read while every real rail sits still. In the tracker's
    /// input it would make the slow counters look live, and 0 W would be back.
    func testGPUEnergyNeverFeedsTheTracker() {
        let gpuEnergy = PowerSampler.Rail(group: "Energy Model", subgroup: "", name: "GPU Energy", energy: 1)
        XCTAssertFalse(gpuEnergy.isEnergyRail)
        for name in ["CPU Energy", "EACC_CPU", "PACC0_CPU", "GPU0", "GPU SRAM0", "ANE0", "DRAM0"] {
            XCTAssertTrue(PowerSampler.Rail(group: "Energy Model", subgroup: "", name: name, energy: 1).isEnergyRail, name)
        }
    }

    /// PMP only contributes its energy counters (base M1). Its stall histograms and heap statistics
    /// — which on an M1 Max under macOS 27 is everything PMP has — are not energy.
    func testOnlyPMPsEnergyCountersAreRails() {
        XCTAssertTrue(PowerSampler.Rail(group: "PMP", subgroup: "Energy Counters", name: "ANE", energy: 1).isEnergyRail)
        XCTAssertFalse(PowerSampler.Rail(group: "PMP", subgroup: "EACC0", name: "DRAM Stall", energy: 1).isEnergyRail)
        XCTAssertFalse(PowerSampler.Rail(group: "PMP", subgroup: "Power", name: "Free heap", energy: 1).isEnergyRail)
    }

    /// The averaged path rebuilds rails from the tracker's keys; a key that did not round-trip would
    /// drop a rail from the averaged wattages only.
    func testARailSurvivesTheTrackerKey() {
        let r = PowerSampler.Rail(group: "PMP", subgroup: "Energy Counters", name: "PCPU", energy: 42)
        let back = PowerSampler.Rail(key: r.key, energy: 42)
        XCTAssertEqual([back.group, back.subgroup, back.name], ["PMP", "Energy Counters", "PCPU"])
    }

    /// One classifier serves both paths, so an averaged window splits power exactly as a live slice
    /// would: 60 J over 60 s of E, P and ANE rails is 1 W each.
    func testTheAveragedPathClassifiesLikeTheLivePath() {
        let rails = [
            PowerSampler.Rail(group: "Energy Model", subgroup: "", name: "CPU Energy", energy: 120_000),
            PowerSampler.Rail(group: "Energy Model", subgroup: "", name: "EACC_CPU", energy: 60_000),
            PowerSampler.Rail(group: "Energy Model", subgroup: "", name: "PACC0_CPU", energy: 60_000),
            PowerSampler.Rail(group: "Energy Model", subgroup: "", name: "ANE0", energy: 60_000),
        ]
        let p = PowerSampler.classify(rails, seconds: 60)
        XCTAssertEqual(p.cpuWatts, 2, accuracy: 1e-9)
        XCTAssertEqual(p.eCPUWatts, 1, accuracy: 1e-9)
        XCTAssertEqual(p.pCPUWatts, 1, accuracy: 1e-9)
        XCTAssertEqual(p.aneWatts, 1, accuracy: 1e-9)
    }

    // MARK: - Unknown power downstream

    private func unknownPower() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.power.railWindowSeconds = 0          // slow counters, no window yet
        return s
    }

    /// The history gets a gap, not a stretch of 0 W that would read as an idle SoC.
    func testUnknownPowerIsAGapInTheHistory() {
        let engine = MetricsEngine(topology: nil)
        engine.ingest(unknownPower(), dt: 1)
        XCTAssertTrue(engine.history.soc.last?.isNaN ?? false)
        XCTAssertTrue(engine.history.ane.last?.isNaN ?? false)
    }

    /// Nor may placeholder zeros drag the ANE peak down while nothing is known.
    func testUnknownPowerDoesNotMoveTheANEPeak() {
        let engine = MetricsEngine(topology: nil)
        var hot = SystemSnapshot()
        hot.power.aneWatts = 9
        engine.ingest(hot, dt: 1)
        let peak = engine.anePeakWatts
        for _ in 0..<100 { engine.ingest(unknownPower(), dt: 1) }
        XCTAssertEqual(engine.anePeakWatts, peak, accuracy: 1e-9)
    }

    /// An average is a reading: it goes into the history like any other.
    func testAnAveragedReadingIsRecorded() {
        let engine = MetricsEngine(topology: nil)
        var s = SystemSnapshot()
        s.power.aneWatts = 3
        s.power.railWindowSeconds = 612
        engine.ingest(s, dt: 1)
        XCTAssertEqual(engine.history.ane.last, 3)
    }

    // MARK: - Recordings and the wire

    /// A recording made before this change has no window field. Its numbers were live readings and
    /// must still decode as exactly that.
    func testAnOldRecordingsPowerIsLive() throws {
        let json = #"{"eCPUWatts":1,"pCPUWatts":2,"cpuWatts":3,"gpuWatts":4,"aneWatts":5,"dramWatts":6}"#
        let p = try JSONDecoder().decode(PowerSample.self, from: Data(json.utf8))
        XCTAssertNil(p.railWindowSeconds)
        XCTAssertTrue(p.railsKnown)
        XCTAssertFalse(p.railsAveraged)
    }

    /// A remote Mac on macOS 27 says how its watts were measured, and the viewer believes it.
    func testTheBasisTravelsWithARemoteMacsPower() throws {
        var s = SystemSnapshot()
        s.power.aneWatts = 2
        s.power.railWindowSeconds = 612
        let topo = CPUTopology(chipName: "Apple M3 Max", eCoreCount: 4, pCoreCount: 10,
                               eFreqsMHz: [], pFreqsMHz: [], gpuFreqsMHz: [])
        let m = MachineMetrics.mac(snapshot: s, topology: topo, hostname: "h", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 0,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0)
        let wire = try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(wire.toDashboardSnapshot().snapshot.power.railWindowSeconds, 612)
    }
}

/// The GPU on its own clock (#65's actual complaint: "the GPU is busy and W reads 0").
final class LiveGPUOnSlowRailsTests: XCTestCase {

    /// "GPU Energy" counts nanojoules. Read as millijoules it was ~150,000 W, which is why it was
    /// excluded from the rails; the conversion is what makes it usable now.
    func testGPUEnergyIsNanojoules() {
        // 0.726 J over 6 s, measured on an idle M1 Max GPU → 0.121 W.
        XCTAssertEqual(PowerSampler.nanojouleWatts(726_211_270, seconds: 6), 0.121, accuracy: 0.001)
    }

    /// Rails pending, GPU live: the GPU figure is a reading, everything else is not.
    func testALiveGPUIsKnownWhileTheRailsAreNot() {
        var p = PowerSample()
        p.railWindowSeconds = 0
        p.gpuWindowSeconds = 0.2
        p.gpuWatts = 18
        XCTAssertFalse(p.railsKnown)
        XCTAssertTrue(p.gpuKnown)
        XCTAssertTrue(p.gpuLive)
    }

    /// ⚠️ The SoC total adds terms that must cover one span. A live GPU plus a half-hour CPU average
    /// describes no moment; the GPU's share over the rails' own window is what gets added.
    func testTheSoCTotalUsesTheGPUShareOverTheRailsWindow() {
        var p = PowerSample()
        p.cpuWatts = 4; p.aneWatts = 0.1; p.dramWatts = 2
        p.railWindowSeconds = 1800
        p.railsGPUWatts = 0.3          // GPU0 + SRAM over the same half hour
        p.gpuWatts = 25                // right now, mid-render
        p.gpuWindowSeconds = 0.2
        XCTAssertEqual(p.socWatts, 6.4, accuracy: 1e-9)
    }

    /// An unknown total must not borrow the live GPU figure.
    func testAnUnknownTotalDoesNotBecomeTheGPUFigure() {
        var p = PowerSample()
        p.railWindowSeconds = 0
        p.gpuWindowSeconds = 0.2
        p.gpuWatts = 1.35
        XCTAssertEqual(p.socWatts, 0)
        XCTAssertFalse(p.railsKnown)
    }

    /// Where the rails are live (macOS ≤ 26) nothing about the GPU changes.
    func testLiveRailsKeepTheGPUOnTheRailsBasis() {
        var p = PowerSample()
        p.gpuWatts = 7
        XCTAssertNil(p.gpuWindowSeconds)
        XCTAssertTrue(p.gpuLive)
        XCTAssertEqual(p.socWatts, 7, accuracy: 1e-9)
    }

    /// Present-tense claims need present-tense power. A half-hour ANE average above the threshold
    /// must not make the workload read "ANE (CoreML)" now, nor latch the ANE as active.
    func testAnAveragedANEFigureMakesNoPresentTenseClaim() {
        var s = SystemSnapshot()
        s.power.aneWatts = 4
        s.power.railWindowSeconds = 1800
        XCTAssertNotEqual(s.likelyAIEngine, "ANE (CoreML)")

        var activity = EngineActivity()
        for _ in 0..<10 { activity.update(s) }
        XCTAssertFalse(activity.ane)
    }

    /// The GPU latch still works from utilisation when its power is not live.
    func testTheGPULatchRunsOnUtilisationWhenPowerIsUnknown() {
        var s = SystemSnapshot()
        s.gpu.usage = 0.9
        s.power.railWindowSeconds = 0
        s.power.gpuWindowSeconds = 0
        var activity = EngineActivity()
        for _ in 0..<6 { activity.update(s) }
        XCTAssertTrue(activity.gpu)
    }

    /// A remote Mac says how its GPU figure was measured, separately from the rails.
    func testTheGPUBasisTravelsOnTheWire() throws {
        var s = SystemSnapshot()
        s.power.railWindowSeconds = 0
        s.power.gpuWindowSeconds = 0.2
        s.power.gpuWatts = 12
        let topo = CPUTopology(chipName: "Apple M1 Max", eCoreCount: 2, pCoreCount: 8,
                               eFreqsMHz: [], pFreqsMHz: [], gpuFreqsMHz: [])
        let m = MachineMetrics.mac(snapshot: s, topology: topo, hostname: "h", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 0,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0)
        let p = try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m))
            .toDashboardSnapshot().snapshot.power
        XCTAssertTrue(p.gpuLive)
        XCTAssertFalse(p.railsKnown)
        XCTAssertEqual(p.gpuWatts, 12)
    }
}
