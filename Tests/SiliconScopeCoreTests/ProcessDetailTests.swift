//
//  File:      ProcessDetailTests.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests the pure rate math of ProcessDetail.derive — first-sample-no-rates, CPU%/IPC/
//             power/disk/wakeup deltas over dt, the not-own guard, ANE-memory gauge, and the
//             history roll/cap. No syscalls (raw ProcRaw values are constructed directly).
//  Notes:     machToNs = 1 in tests (treat mach ticks as ns) so the arithmetic is exact.
//
import XCTest
@testable import SiliconScopeCore

final class ProcessDetailTests: XCTestCase {

    private func raw(user: UInt64 = 0, userP: UInt64 = 0, sys: UInt64 = 0,
                     instr: UInt64 = 0, cycles: UInt64 = 0, energyNj: UInt64 = 0,
                     diskR: UInt64 = 0, idleWk: UInt64 = 0, intWk: UInt64 = 0,
                     footprint: UInt64 = 0, neural: UInt64 = 0) -> ProcRaw {
        var r = ProcRaw()
        r.userTimeMach = user; r.userPTimeMach = userP; r.systemTimeMach = sys
        r.instructions = instr; r.cycles = cycles; r.energyNanojoules = energyNj
        r.diskReadBytes = diskR; r.idleWakeups = idleWk; r.interruptWakeups = intWk
        r.physFootprint = footprint; r.neuralFootprint = neural; r.startAbstime = 1
        return r
    }
    private func derive(_ prev: ProcRaw?, _ cur: ProcRaw, dt: TimeInterval = 1, own: Bool = true) -> ProcessDetail {
        ProcessDetail.derive(pid: 42, name: "t", path: "/t", isOwn: own,
                             prev: prev, cur: cur, dt: dt, nowMach: 0, machToNs: 1)
    }

    func testFirstSampleHasGaugesButNoRates() {
        let d = derive(nil, raw(footprint: 1_048_576, neural: 2_097_152))
        XCTAssertNil(d.cpuPercent)
        XCTAssertNil(d.powerWatts)
        XCTAssertEqual(d.memoryBytes, 1_048_576)
        XCTAssertEqual(d.aneMemoryBytes, 2_097_152)
        XCTAssertTrue(d.usesANE)
    }

    func testRatesOverDt() {
        let prev = raw()
        let cur = raw(user: 500_000_000, instr: 1000, cycles: 500, energyNj: 3_000_000_000,
                      diskR: 2000, idleWk: 10, intWk: 5)
        let d = derive(prev, cur, dt: 1)
        XCTAssertEqual(d.cpuPercent ?? 0, 50, accuracy: 0.01)        // 5e8 ns busy / 1s
        XCTAssertEqual(d.ipc ?? 0, 2.0, accuracy: 0.001)            // 1000 / 500
        XCTAssertEqual(d.instructionsPerSec ?? 0, 1000, accuracy: 0.1)
        XCTAssertEqual(d.powerWatts ?? 0, 3.0, accuracy: 0.001)     // 3e9 nJ → 3 J / 1s
        XCTAssertEqual(d.diskReadBytesPerSec ?? 0, 2000, accuracy: 0.1)
        XCTAssertEqual(d.wakeupsPerSec ?? 0, 15, accuracy: 0.1)
    }

    func testPCoreSplit() {
        let d = derive(raw(), raw(user: 400_000_000, userP: 300_000_000), dt: 1)
        XCTAssertEqual(d.cpuPercent ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(d.cpuPPercent ?? 0, 30, accuracy: 0.01)      // E = total - P = 10%
    }

    func testNotOwnHasNoRates() {
        let d = derive(raw(), raw(user: 500_000_000), dt: 1, own: false)
        XCTAssertNil(d.cpuPercent)
        XCTAssertFalse(d.isOwn)
    }

    func testIPCNilWhenNoCycles() {
        let d = derive(raw(), raw(instr: 1000, cycles: 0), dt: 1)
        XCTAssertNil(d.ipc)
    }

    func testHistoryRollsTo60() {
        var h = ProcessDetailHistory()
        for _ in 0..<70 { h.push(derive(raw(), raw(user: 100_000_000), dt: 1)) }
        XCTAssertEqual(h.cpu.count, 60)
    }
}
