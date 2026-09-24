//
//  File:      RemoteParityTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the last step of remote/local parity (#56): a remote Mac's AI runtimes and
//             loaded model, its busiest processes, and its battery.
//  Notes:     Everything round-trips through real JSON — the failures worth guarding are wire
//             failures: an enum value the viewer does not know, a block an old agent never sent, and
//             a field that must never leave the machine at all.
//
import XCTest
@testable import SiliconScopeCore

final class RemoteParityTests: XCTestCase {

    private let topology = CPUTopology(chipName: "Apple M4 Pro", eCoreCount: 4, pCoreCount: 10,
                                       eFreqsMHz: [], pFreqsMHz: [], gpuFreqsMHz: [])

    private func served(_ s: SystemSnapshot) throws -> MachineMetrics {
        let m = MachineMetrics.mac(snapshot: s, topology: topology, hostname: "studio", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 1,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0)
        return try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m))
    }

    private func machineServingAModel() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.memory.totalBytes = 64 << 30
        s.memory.wiredBytes = 20 << 30
        s.aiRuntime.processes = [
            AIRuntimeProcess(pid: 10, kind: .lmStudio, displayName: "LM Studio", cpuPercent: 3,
                             memoryBytes: 18 << 30, embeddedPort: nil),
        ]
        s.runtimeAPI.status = .ok
        s.runtimeAPI.source = .lmStudio
        s.runtimeAPI.loadedModels = [RuntimeModelInfo(name: "qwen/qwen3.8-27b", sizeBytes: 0, sizeVRAMBytes: 0,
                                                      parameterSize: nil, quantization: "Q4_K_M", contextLength: 8192)]
        s.processes = [
            ProcessRow(pid: 10, name: "node", cpuPercent: 3, memoryBytes: 18 << 30,
                       path: "/Users/x/.lmstudio/.internal/utils/node", args: "node --api-key sk-SECRET"),
            ProcessRow(pid: 20, name: "Xcode", cpuPercent: 80, memoryBytes: 2 << 30),
        ]
        s.battery.hasBattery = true
        s.battery.percent = 80
        s.battery.isPluggedIn = true
        return s
    }

    // MARK: - What arrives

    func testTheRuntimeAndItsLoadedModelArrive() throws {
        let (s, _) = try served(machineServingAModel()).toDashboardSnapshot()
        XCTAssertEqual(s.aiRuntime.primaryKind, .lmStudio)
        XCTAssertEqual(s.aiRuntime.primaryMemoryBytes, 18 << 30)
        XCTAssertEqual(s.runtimeAPI.status, .ok)
        XCTAssertEqual(s.runtimeAPI.primaryModel?.name, "qwen/qwen3.8-27b")
        XCTAssertEqual(s.runtimeAPI.primaryModel?.quantization, "Q4_K_M")
    }

    /// The budget is recomputed from what arrived, with the runtime's footprint lifting "loadable"
    /// exactly as it does on the machine itself.
    func testTheModelBudgetCountsTheRemoteRuntime() throws {
        var s = machineServingAModel()
        let (withRuntime, _) = try served(s).toDashboardSnapshot()
        s.aiRuntime.processes = []
        let (without, _) = try served(s).toDashboardSnapshot()
        XCTAssertGreaterThan(withRuntime.memoryBudget.loadableBytes, without.memoryBudget.loadableBytes)
    }

    func testProcessesAndBatteryArrive() throws {
        let (s, _) = try served(machineServingAModel()).toDashboardSnapshot()
        XCTAssertEqual(Set(s.processes.map(\.name)), ["node", "Xcode"])
        XCTAssertTrue(s.battery.hasBattery)
        XCTAssertEqual(s.battery.percent, 80)
        XCTAssertTrue(s.battery.isPluggedIn)
    }

    // MARK: - What must never leave the machine

    /// ⚠️ A command line is where people put secrets. The wire carries the process NAME only —
    /// checked on the JSON itself, not just on the decoded type.
    func testNoPathOrArgumentsEverTravel() throws {
        let m = MachineMetrics.mac(snapshot: machineServingAModel(), topology: topology, hostname: "h",
                                   machineId: "m", osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0,
                                   loadAvg1: 0, anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1,
                                   gpuClockPeakMHz: 0)
        let json = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains(".lmstudio/.internal"))
    }

    /// Both rankings are represented, so either sort on the remote card starts from its real leaders:
    /// a process with a huge footprint but no CPU still makes it across.
    func testTheBusiestAndTheLargestBothTravel() {
        var rows = (0..<200).map { ProcessRow(pid: Int32($0), name: "p\($0)", cpuPercent: Double($0), memoryBytes: 1) }
        rows.append(ProcessRow(pid: 999, name: "big-idle", cpuPercent: 0, memoryBytes: 40 << 30))
        let sent = MachineMetrics.reportedProcesses(rows)
        XCTAssertTrue(sent.contains { $0.name == "big-idle" })
        XCTAssertTrue(sent.contains { $0.name == "p199" })
        XCTAssertLessThanOrEqual(sent.count, 2 * MachineMetrics.reportedProcessCount)
        XCTAssertEqual(Set(sent.map(\.pid)).count, sent.count, "no process is sent twice")
    }

    // MARK: - Not reported is not "none"

    /// Nobody asked the runtime's API → the answer travels as absent, and the viewer keeps the
    /// "disabled" status that it renders as "not reported by this machine" — never "no model loaded".
    func testAnUnaskedAPIIsNotReportedRatherThanEmpty() throws {
        var s = machineServingAModel()
        s.runtimeAPI = RuntimeAPISample()
        let m = try served(s)
        XCTAssertNil(m.aiRuntime?.api)
        XCTAssertEqual(m.toDashboardSnapshot().snapshot.runtimeAPI.status, .disabled)
        XCTAssertEqual(m.toDashboardSnapshot().snapshot.aiRuntime.primaryKind, .lmStudio, "identity still arrives")
    }

    /// A desktop sends no battery block, and the header shows none.
    func testADesktopHasNoBatteryBlock() throws {
        var s = machineServingAModel()
        s.battery = BatteryInfo()
        XCTAssertNil(try served(s).battery)
    }

    /// An agent from before this step sent none of the three blocks — the viewer can tell, which is
    /// what keeps it on the reduced layout instead of drawing empty cards.
    func testAnOldAgentReportsNoneOfTheBlocks() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"macOS 26.6","kind":"mac","agentVersion":"1.1.0","ts":0,
         "cpu":{"cores":10,"usagePercent":4,"loadAvg1":1},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1}}
        """
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertNil(m.aiRuntime); XCTAssertNil(m.processes); XCTAssertNil(m.battery)
    }

    /// ⚠️ A newer agent's runtime kind or API status must degrade, not throw — one unknown string
    /// would otherwise take the whole machine offline in the viewer (#33's shape).
    func testUnknownRuntimeKindAndStatusDegrade() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"macOS 28.0","kind":"mac","agentVersion":"9.0","ts":0,
         "cpu":{"cores":10,"usagePercent":4,"loadAvg1":1},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},
         "aiRuntime":{"processes":[{"pid":1,"kind":"hyperllm","cpuPercent":1,"memoryBytes":5}],
                      "api":{"status":"thinking","source":"hyperllm","models":[],"tokensPerSec":null}}}
        """
        let (s, _) = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8)).toDashboardSnapshot()
        XCTAssertEqual(s.aiRuntime.primaryKind, .other)
        XCTAssertEqual(s.runtimeAPI.status, .unreachable)
        XCTAssertNil(s.runtimeAPI.source)
    }
}
