//
//  File:      EngineActivityTests.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the anti-flapping behaviour of the AI Workload card's engine rows: a value
//             sitting on a threshold must not alternate active/idle every tick, and a single spike
//             or dropout must not flip the label.
//  Notes:     This is the kind of behaviour that is nearly impossible to confirm by looking at a
//             running app — you would have to watch a boundary for a minute and count flips — so it
//             is pinned here instead. Ticks are synthetic; no hardware is read.
//
import XCTest
@testable import SiliconScopeCore

final class EngineActivityTests: XCTestCase {

    /// A GPU sample parked between the off and on thresholds. Without hysteresis this alternates
    /// every tick; with it, the state never leaves where it started.
    func testValueBetweenThresholdsNeverFlips() {
        var activity = EngineActivity()
        var s = SystemSnapshot()
        s.gpu.usage = 0.32          // above gpuUsageOff (0.25), below gpuUsageOn (0.40)

        for _ in 0..<40 { activity.update(s) }
        XCTAssertFalse(activity.gpu, "must not turn on below the ON threshold")

        // Drive it on, then park at the same in-between value.
        s.gpu.usage = 0.90
        for _ in 0..<5 { activity.update(s) }
        XCTAssertTrue(activity.gpu)

        s.gpu.usage = 0.32
        for _ in 0..<40 { activity.update(s) }
        XCTAssertTrue(activity.gpu, "must not turn off above the OFF threshold")
    }

    /// One tick over the line is a spike, not a workload.
    func testSingleSpikeDoesNotTurnOn() {
        var activity = EngineActivity()
        var idle = SystemSnapshot()
        idle.gpu.usage = 0.05
        var spike = SystemSnapshot()
        spike.gpu.usage = 0.95

        activity.update(idle)
        activity.update(spike)
        XCTAssertFalse(activity.gpu, "a single sample must not flip the label")
        activity.update(idle)
        XCTAssertFalse(activity.gpu)
    }

    /// One quiet tick during real work is a dropout, not the end of the workload.
    func testSingleDropoutDoesNotTurnOff() {
        var activity = EngineActivity()
        var busy = SystemSnapshot()
        busy.gpu.usage = 0.95
        var quiet = SystemSnapshot()
        quiet.gpu.usage = 0.0

        for _ in 0..<5 { activity.update(busy) }
        XCTAssertTrue(activity.gpu)

        activity.update(quiet)
        XCTAssertTrue(activity.gpu, "one dropout must not clear it")
        for _ in 0..<5 { activity.update(busy) }
        XCTAssertTrue(activity.gpu)
    }

    /// Sustained work turns on, and sustained quiet turns off — the latch must not be a mute.
    func testSustainedChangeIsHonoured() {
        var activity = EngineActivity()
        var busy = SystemSnapshot()
        busy.gpu.usage = 0.95
        var quiet = SystemSnapshot()
        quiet.gpu.usage = 0.0

        for _ in 0..<3 { activity.update(busy) }
        XCTAssertTrue(activity.gpu)
        for _ in 0..<6 { activity.update(quiet) }
        XCTAssertFalse(activity.gpu)
    }

    /// Turning on is quicker than turning off: an engine lighting up is the event worth seeing.
    func testOnIsFasterThanOff() {
        var activity = EngineActivity()
        var busy = SystemSnapshot()
        busy.gpu.usage = 0.95
        var quiet = SystemSnapshot()
        quiet.gpu.usage = 0.0

        var ticksToOn = 0
        while !activity.gpu, ticksToOn < 20 { activity.update(busy); ticksToOn += 1 }
        var ticksToOff = 0
        while activity.gpu, ticksToOff < 20 { activity.update(quiet); ticksToOff += 1 }

        XCTAssertLessThan(ticksToOn, ticksToOff)
    }

    /// The CPU thresholds are what the AI Workload card contradicting itself came down to: E-cores
    /// at 64 % with a process burning 199 % used to read "Idle".
    func testBusyEfficiencyCoresReadAsActive() {
        var activity = EngineActivity()
        var s = SystemSnapshot()
        s.cpu.eUsage = 0.64
        s.cpu.pUsage = 0.33

        for _ in 0..<4 { activity.update(s) }
        XCTAssertTrue(activity.cpu)
    }

    /// A machine at rest stays quiet — the lowered thresholds must not make "Active" permanent.
    func testRestingMachineReadsIdle() {
        var activity = EngineActivity()
        var s = SystemSnapshot()
        s.cpu.eUsage = 0.12
        s.cpu.pUsage = 0.02
        s.gpu.usage = 0.03
        s.power.gpuWatts = 0.1

        for _ in 0..<20 { activity.update(s) }
        XCTAssertFalse(activity.cpu)
        XCTAssertFalse(activity.gpu)
    }

    /// Surfaces with no time series seed from the sample and agree with where a latch settles.
    func testInstantSeedMatchesSettledLatch() {
        var s = SystemSnapshot()
        s.power.aneWatts = 3.3
        s.gpu.usage = 0.9

        var latched = EngineActivity()
        for _ in 0..<8 { latched.update(s) }
        let instant = EngineActivity(instant: s)

        XCTAssertEqual(instant.ane, latched.ane)
        XCTAssertEqual(instant.gpu, latched.gpu)
        XCTAssertTrue(instant.ane)
    }
}
