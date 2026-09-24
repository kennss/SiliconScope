//
//  File:      RemoteIOTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in step 2 of remote/local parity (#56): a remote Mac's disk capacity and its
//             disk + network throughput, which fill the remote Network & Disk card.
//  Notes:     Throughput is the agent's own rate over its own elapsed time; the viewer copies it
//             and never re-derives it. Capacity rides the existing `disks` array the Linux agent
//             already fills, so both kinds of machine describe a volume the same way.
//
import XCTest
@testable import SiliconScopeCore

final class RemoteIOTests: XCTestCase {

    private let topology = CPUTopology(chipName: "Apple M1 Max", eCoreCount: 2, pCoreCount: 8,
                                       eFreqsMHz: [2064], pFreqsMHz: [3228], gpuFreqsMHz: [1296])

    private func served(_ s: SystemSnapshot) throws -> MachineMetrics {
        let m = MachineMetrics.mac(snapshot: s, topology: topology, hostname: "studio", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 1,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0)
        return try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m))
    }

    private func busy() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.disk.readBytesPerSec = 19_600_000
        s.disk.writeBytesPerSec = 68_000
        s.disk.totalBytes = 4_000_000_000_000
        s.disk.freeBytes = 1_200_000_000_000
        s.network.downloadBytesPerSec = 12_000
        s.network.uploadBytesPerSec = 25_000
        return s
    }

    func testThroughputAndCapacitySurviveTheWire() throws {
        let (s, _) = try served(busy()).toDashboardSnapshot()
        XCTAssertEqual(s.disk.readBytesPerSec, 19_600_000)
        XCTAssertEqual(s.disk.writeBytesPerSec, 68_000)
        XCTAssertEqual(s.network.downloadBytesPerSec, 12_000)
        XCTAssertEqual(s.network.uploadBytesPerSec, 25_000)
        XCTAssertEqual(s.disk.totalBytes, 4_000_000_000_000)
        XCTAssertEqual(s.disk.freeBytes, 1_200_000_000_000)
    }

    /// A Mac names its boot volume the way the Linux agent names a mount, so one reader serves both.
    func testTheBootVolumeTravelsAsRoot() throws {
        XCTAssertEqual(try served(busy()).disks?.map(\.mount), ["/"])
    }

    /// No capacity reading is an absence, not a zero-byte disk.
    func testAnUnreadVolumeIsNotSentAsAnEmptyDisk() throws {
        var s = busy()
        s.disk.totalBytes = 0
        s.disk.freeBytes = 0
        XCTAssertNil(try served(s).disks)
    }

    /// An agent from before this step sends no `io`. It must decode, and the viewer must be able to
    /// tell "not reported" from "idle" — that is what keeps the remote card hidden instead of zeroed.
    func testAnOldAgentReportsNoThroughputRatherThanZeroThroughput() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"macOS 26.6","kind":"mac","agentVersion":"1.1.0","ts":0,
         "cpu":{"cores":10,"usagePercent":4,"loadAvg1":1},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1}}
        """
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertNil(m.io)
        XCTAssertNil(m.disks)
    }

    /// A Linux box sends several volumes largest first and no "/" is guaranteed to lead; the root
    /// wins when present, otherwise the first (largest).
    func testTheRootVolumeIsPreferredOverTheLargest() throws {
        let json = """
        {"machineId":"m","hostname":"nas","os":"linux","kind":"linux","agentVersion":"0.9","ts":0,
         "cpu":{"cores":4,"usagePercent":4,"loadAvg1":1},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},
         "disks":[{"mount":"/volume1","totalBytes":11000,"freeBytes":2000},
                  {"mount":"/","totalBytes":100,"freeBytes":40}]}
        """
        let (s, _) = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8)).toDashboardSnapshot()
        XCTAssertEqual(s.disk.totalBytes, 100)
        XCTAssertEqual(s.disk.freeBytes, 40)
    }
}
