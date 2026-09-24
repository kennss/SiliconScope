//
//  File:      MetricDemandTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in demand-driven sampling and the shape of a gap (#13): a group nobody is
//             looking at is not measured, and the record says so instead of saying zero.
//  Notes:     The numbers in the gap tests are deliberately ones that would survive unnoticed if
//             a gap were written as 0 — an idle GPU really does read 0.0, so a test that only
//             checked "not the old value" would pass on the bug this file exists to prevent.
//
import XCTest
@testable import SiliconScopeCore

final class MetricDemandTests: XCTestCase {

    // MARK: - What a consumer asks for

    /// Every channel resolves to the group that actually produces it. A channel pointing at the
    /// wrong group is the worst failure mode here: the glyph keeps drawing while the sampler it
    /// depends on is switched off, so it shows a value frozen at whatever it last read.
    func testEveryChannelMapsToTheGroupThatProducesIt() {
        XCTAssertEqual(DataChannel.socPower.metricGroup, .power)
        XCTAssertEqual(DataChannel.anePower.metricGroup, .power)
        XCTAssertEqual(DataChannel.cpuEfficiency.metricGroup, .cpu)
        XCTAssertEqual(DataChannel.gpuMemory.metricGroup, .gpu)
        XCTAssertEqual(DataChannel.mediaThroughput.metricGroup, .bandwidth)
        XCTAssertEqual(DataChannel.memoryPressure.metricGroup, .memory)
        XCTAssertEqual(DataChannel.networkUp.metricGroup, .network)
        XCTAssertEqual(DataChannel.diskFree.metricGroup, .disk)
        XCTAssertEqual(DataChannel.sensorSecondaryTemp.metricGroup, .temperature)
        XCTAssertEqual(DataChannel.batteryPercent.metricGroup, .battery)
    }

    /// No channel may map to nothing — a new channel added without a group would silently make
    /// its item invisible to demand.
    func testNoChannelIsUnattributed() {
        for channel in DataChannel.allCases {
            XCTAssertFalse(channel.metricGroup.isEmpty, "\(channel) belongs to no metric group")
        }
    }

    /// The floor is the alert path's floor, and it is cheap on purpose: both are single instant
    /// reads. A monitor that stops noticing memory pressure while its window is shut has stopped
    /// being a monitor.
    func testTheEssentialFloorIsMemoryAndThermal() {
        XCTAssertEqual(MetricGroup.essential, [.memory, .thermal])
        XCTAssertTrue(MetricGroup.all.isSuperset(of: .essential))
    }

    // MARK: - The gap

    /// `socWatts` and `usedGB` are derived, so the fixture sets the stored fields they read.
    private func snapshot(gpu: Double, watts: Double, memGB: Double) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.gpu.usage = gpu
        s.power.measuredSocWatts = watts
        s.memory.totalBytes = 64 << 30
        s.memory.wiredBytes = UInt64(memGB * 1_073_741_824)
        return s
    }

    /// ⚠️ The alignment rule. These series carry no timestamps, so two charts only share a time
    /// axis because they are the same length and advance together. A gap still advances.
    func testEverySeriesAdvancesByOneSlotWhetherOrNotItWasMeasured() {
        var h = MetricsEngine.History()
        h.push(snapshot(gpu: 0.5, watts: 10, memGB: 8))
        h.push(snapshot(gpu: 0.5, watts: 10, memGB: 8), measured: [.memory])
        h.push(snapshot(gpu: 0.5, watts: 10, memGB: 8), measured: [.memory])
        XCTAssertEqual(h.gpu.count, 3)
        XCTAssertEqual(h.soc.count, 3)
        XCTAssertEqual(h.memory.count, 3)
    }

    /// A gap is not a zero. An idle GPU reads 0.0, so the two must be distinguishable or "we did
    /// not look" is indistinguishable from "it was doing nothing".
    func testAnUnmeasuredGroupRecordsAGapRatherThanZero() {
        var h = MetricsEngine.History()
        h.push(snapshot(gpu: 0.0, watts: 0, memGB: 8), measured: .all)
        h.push(snapshot(gpu: 0.0, watts: 0, memGB: 8), measured: [.memory])
        XCTAssertEqual(h.gpu[0], 0.0)              // measured idle
        XCTAssertTrue(h.gpu[1].isNaN)              // not measured
        XCTAssertFalse(h.memory[1].isNaN)          // still demanded, still real
    }

    /// Sensor rows are keyed by whatever the machine reports, so they need the same treatment as
    /// the fixed series — otherwise a temperature gap stalls those rows out of step.
    func testSensorRowsAlsoAdvanceThroughAGap() {
        var s = SystemSnapshot()
        s.temperature.groups = [SensorGroup(category: .cpu, sensors: [
            TempSensor(rawName: "TC0P", name: "CPU", celsius: 44),
        ])]
        var h = MetricsEngine.History()
        h.push(s)
        h.push(s, measured: [.memory])
        XCTAssertEqual(h.sensorGroups[.cpu]?.count, 2)
        XCTAssertTrue(h.sensorGroups[.cpu]?[1].isNaN ?? false)
    }

    // MARK: - Things that must not swallow a gap

    /// `withoutGaps` is the only sanctioned way to reduce a series.
    func testAggregationsIgnoreGaps() {
        let series: [Double] = [3, .nan, 9, .nan, 1]
        XCTAssertEqual(series.withoutGaps, [3, 9, 1])
        XCTAssertEqual(series.withoutGaps.max(), 9)
        XCTAssertEqual(series.withoutGaps.min(), 1)
    }

    /// ⚠️ The trap that makes a gap LOUD. `min(1, .nan)` is 1 in Swift — every comparison with
    /// NaN is false, so the clamp keeps the other operand. Mapped over a series, an unmeasured
    /// tick would render as a full-scale spike.
    func testScalingAGapDoesNotProduceAFullScaleSpike() {
        XCTAssertEqual(Swift.min(1, Double.nan / 2), 1, "the trap still exists — the helper is why")
        XCTAssertTrue(Double.nan.scaledToCeiling(2).isNaN)
        XCTAssertEqual((1.0).scaledToCeiling(2), 0.5)
        XCTAssertEqual((8.0).scaledToCeiling(2), 1, "real values still clamp")
    }

    // MARK: - Carry-forward

    /// The published snapshot keeps the last real value for a group it did not measure, so the
    /// frame a window reopens on is not a wall of zeros. The history is told the truth separately.
    func testCarryForwardKeepsOnlyWhatWasNotMeasured() {
        let previous = snapshot(gpu: 0.8, watts: 22, memGB: 30)
        let fresh = snapshot(gpu: 0, watts: 0, memGB: 12)      // only memory was read
        let merged = fresh.carryingForward(previous, measured: [.memory])
        XCTAssertEqual(merged.memory.usedGB, 12, "the measured group must be the NEW reading")
        XCTAssertEqual(merged.gpu.usage, 0.8)
        XCTAssertEqual(merged.power.socWatts, 22)
    }

    func testCarryForwardChangesNothingWhenEverythingWasMeasured() {
        let previous = snapshot(gpu: 0.8, watts: 22, memGB: 30)
        let fresh = snapshot(gpu: 0.1, watts: 3, memGB: 12)
        let merged = fresh.carryingForward(previous, measured: .all)
        XCTAssertEqual(merged.gpu.usage, 0.1)
        XCTAssertEqual(merged.power.socWatts, 3)
    }

    // MARK: - Peaks and latches across a gap

    /// ⚠️ The peaks DECAY every time they are folded. Folding a carried-forward value would let a
    /// peak drift on the strength of one old reading repeated, so an unmeasured group's peak is
    /// left strictly alone and resumes where the last real reading left it.
    func testAnUnmeasuredGroupNeitherRaisesNorDecaysItsPeak() {
        let engine = MetricsEngine(topology: nil)
        var hot = SystemSnapshot()
        hot.power.aneWatts = 12
        engine.ingest(hot, dt: 1)
        let peak = engine.anePeakWatts
        XCTAssertEqual(peak, 12, accuracy: 0.001)

        for _ in 0..<50 { engine.ingest(SystemSnapshot(), dt: 1, measured: [.memory]) }
        XCTAssertEqual(engine.anePeakWatts, peak, accuracy: 0.001, "a gap must not move the peak")
    }

    /// The dwell latches flip after N consecutive agreeing samples. Re-feeding a carried-forward
    /// value would count as fresh agreement; a gap must simply hold the last verdict.
    func testActivityLatchesHoldThroughAGap() {
        var activity = EngineActivity()
        var busy = SystemSnapshot()
        busy.cpu.pUsage = 0.95
        for _ in 0..<6 { activity.update(busy) }
        XCTAssertTrue(activity.cpu)

        for _ in 0..<20 { activity.update(SystemSnapshot(), measured: [.memory]) }
        XCTAssertTrue(activity.cpu, "an unmeasured CPU must not latch OFF on a zeroed sample")
    }
}
