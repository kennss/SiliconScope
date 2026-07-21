//
//  File:      FleetMetricsTests.swift
//  Created:   2026-07-21
//  Updated:   2026-07-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins that MachineMetrics decodes the Go Linux agent's JSON byte-for-byte. The
//             fixture below is real output captured from the agent on kennt-Ubuntu (RTX 3090),
//             so a schema drift between agent/main.go and MachineMetrics.swift fails here.
//  Notes:     Pure decode test — no network, no hardware.
//
import XCTest
@testable import SiliconScopeCore

final class FleetMetricsTests: XCTestCase {

    // Real capture from `ssh kennt@… /tmp/sscope-agent` (agent v0.1.0), lightly trimmed.
    private let sampleJSON = #"""
    {
      "machineId": "23d59cc72e374700b31875eebdd7030d",
      "hostname": "kennt-Ubuntu",
      "os": "Ubuntu 24.04.4 LTS",
      "kind": "linux",
      "agentVersion": "0.1.0",
      "ts": 1784645251558,
      "cpu": { "cores": 16, "usagePercent": 5, "loadAvg1": 0.03 },
      "memory": { "totalBytes": 67330691072, "usedBytes": 4049244160, "availableBytes": 63281446912 },
      "gpus": [
        {
          "index": 0, "name": "NVIDIA GeForce RTX 3090", "driver": "595.71.05",
          "vramTotalBytes": 25769803776, "vramUsedBytes": 306184192,
          "utilizationPercent": 0, "temperatureC": 41, "powerDrawW": 35.26, "powerLimitW": 390,
          "processes": []
        }
      ],
      "llm": { "ollama": { "running": true,
        "models": [ { "name": "gemma4:12b", "sizeBytes": 7556508396 },
                    { "name": "gemma4:latest", "sizeBytes": 9608350718 } ],
        "loaded": [] } }
    }
    """#

    func testDecodesRealAgentJSON() throws {
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(sampleJSON.utf8))
        XCTAssertEqual(m.machineId, "23d59cc72e374700b31875eebdd7030d")
        XCTAssertEqual(m.hostname, "kennt-Ubuntu")
        XCTAssertEqual(m.kind, "linux")
        XCTAssertEqual(m.id, m.machineId)                     // Identifiable
        XCTAssertEqual(m.cpu.cores, 16)
        XCTAssertEqual(m.cpu.usagePercent, 5, accuracy: 0.001)
        XCTAssertEqual(m.memory.totalBytes, 67330691072)
        XCTAssertEqual(m.gpus.count, 1)
        let g = try XCTUnwrap(m.gpus.first)
        XCTAssertEqual(g.name, "NVIDIA GeForce RTX 3090")
        XCTAssertEqual(g.vramTotalBytes, 25769803776)         // 24 GiB
        XCTAssertEqual(g.powerDrawW, 35.26, accuracy: 0.001)
        XCTAssertEqual(g.powerLimitW, 390, accuracy: 0.001)
        XCTAssertEqual(g.vramFraction, Double(306184192) / Double(25769803776), accuracy: 1e-6)
        XCTAssertTrue(g.processes.isEmpty)
        let ollama = try XCTUnwrap(m.llm?.ollama)
        XCTAssertTrue(ollama.running)
        XCTAssertEqual(ollama.models.map(\.name), ["gemma4:12b", "gemma4:latest"])
        XCTAssertEqual(ollama.models.first?.sizeBytes, 7556508396)
        XCTAssertTrue(ollama.loaded.isEmpty)
    }

    /// A machine with no NVIDIA GPU and no Ollama must still decode (empty gpus, nil llm).
    func testDecodesMinimalMachine() throws {
        let json = #"{"machineId":"x","hostname":"h","os":"o","kind":"linux","agentVersion":"0.1.0","ts":1,"cpu":{"cores":8,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[]}"#
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertTrue(m.gpus.isEmpty)
        XCTAssertNil(m.llm)
    }
}
