//
//  File:      FleetMultiGPUTests.swift
//  Created:   2026-10-18
//  Updated:   2026-10-18
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins a box with several GPUs on the wire: each card's UUID and processes, the account
//             a process runs as, what a card's history is keyed on, and the header's GPU phrase.
//  Notes:     GPU 0 follows agent 1.5's output on kennt-Ubuntu (RTX 3090, driver 595); GPU 1 is a
//             fixture in the same shape. An agent before 1.5 sends neither `uuid` nor `user`, and
//             must still decode.
//
import XCTest
@testable import SiliconScopeCore

final class FleetMultiGPUTests: XCTestCase {

    private func machine(gpus: String) throws -> MachineMetrics {
        let json = #"{"machineId":"x","hostname":"kennt-Ubuntu","os":"Ubuntu","kind":"linux","agentVersion":"1.5.0","ts":1,"cpu":{"cores":16,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":"# + gpus + "}"
        return try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
    }

    private func gpu(_ index: Int, uuid: String?, procs: String = "[]") -> String {
        let id = uuid.map { #","uuid":"\#($0)""# } ?? ""
        return #"{"index":\#(index)\#(id),"name":"NVIDIA GeForce RTX 3090","driver":"595.84","vramTotalBytes":25769803776,"vramUsedBytes":6304038912,"utilizationPercent":37,"temperatureC":48,"powerDrawW":112,"powerLimitW":350,"processes":\#(procs)}"#
    }

    func testEachCardKeepsItsOwnUUIDAndProcesses() throws {
        let m = try machine(gpus: "[" + gpu(0, uuid: "GPU-d5a8caa7-b8c9-a066-415f-550d411855cb",
                                            procs: #"[{"pid":2724,"name":"/home/kennt/whisper-bench/bin/python","vramBytes":5670699008,"script":"server.py","user":"kennt"}]"#)
                                 + "," + gpu(1, uuid: "GPU-0f6a1c2e-1111-2222-3333-444455556666",
                                             procs: #"[{"pid":4100,"name":"/opt/train/bin/python","vramBytes":19327352832,"user":"1001"}]"#) + "]")
        XCTAssertEqual(m.gpus.count, 2)
        XCTAssertEqual(m.gpus[0].uuid, "GPU-d5a8caa7-b8c9-a066-415f-550d411855cb")
        XCTAssertEqual(m.gpus[0].processes.map(\.pid), [2724])
        XCTAssertEqual(m.gpus[1].processes.map(\.pid), [4100])
        XCTAssertEqual(m.gpus[0].processes.first?.user, "kennt")
        XCTAssertEqual(m.gpus[1].processes.first?.user, "1001", "an account the host can't name stays a uid")
    }

    func testAnAgentBeforeUUIDsStillDecodes() throws {
        let m = try machine(gpus: "[" + gpu(0, uuid: nil,
                                            procs: #"[{"pid":2720,"name":"/home/kennt/ComfyUI/venv/bin/python","vramBytes":268435456}]"#) + "]")
        XCTAssertNil(m.gpus[0].uuid)
        XCTAssertNil(m.gpus[0].processes.first?.user)
    }

    /// The UUID follows the card; the index is only a fallback for agents that don't send one.
    func testHistoryIsKeyedOnTheUUIDElseTheIndex() throws {
        let m = try machine(gpus: "[" + gpu(0, uuid: "GPU-a") + "," + gpu(1, uuid: nil) + "]")
        XCTAssertEqual(m.gpus[0].historyKey, "uuid:GPU-a")
        XCTAssertEqual(m.gpus[1].historyKey, "index:1")
        XCTAssertNotEqual(m.gpus[0].id, m.gpus[1].id)
    }

    func testInventoryLabel() {
        func card(_ name: String, _ gb: Int64) -> FleetGPU {
            FleetGPU(index: 0, name: name, driver: "d", vramTotalBytes: gb, vramUsedBytes: 0,
                     utilizationPercent: 0, temperatureC: 0, powerDrawW: 0, powerLimitW: 0, processes: [])
        }
        let memory = { (b: Int64) in "\(b) GB" }
        XCTAssertNil(FleetGPU.inventoryLabel([], memory: memory))
        XCTAssertEqual(FleetGPU.inventoryLabel([card("RTX 3090", 24)], memory: memory), "RTX 3090 24 GB")
        XCTAssertEqual(FleetGPU.inventoryLabel([card("RTX 3090", 24), card("RTX 3090", 24)], memory: memory),
                       "2× RTX 3090 24 GB")
        XCTAssertEqual(FleetGPU.inventoryLabel([card("RTX 4090", 24), card("RTX 3090", 24)], memory: memory),
                       "RTX 4090 24 GB + RTX 3090 24 GB")
    }
}
