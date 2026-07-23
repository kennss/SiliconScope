//
//  File:      FleetMetricsTests.swift
//  Created:   2026-07-21
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins that MachineMetrics decodes each agent's JSON byte-for-byte, and that a Mac
//             payload maps into the synthesized dashboard snapshot correctly. Both fixtures are
//             real captures — the Go Linux agent on kennt-Ubuntu (RTX 3090) and the Mac agent on an
//             M1 MacBook Air — so schema drift between agent and MachineMetrics.swift fails here.
//  Notes:     Pure decode/map tests — no network, no hardware. The Linux fixture deliberately omits
//             the Apple-only memory split, which also pins backward compatibility of those Optionals.
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

    /// A GPU-less Linux box (Raspberry Pi, CPU-only server, VM) sends `"gpus": null`, because Go
    /// marshals a nil slice as null. That threw `valueNotFound` and took the whole machine offline
    /// in the viewer — issue #33. Every array in the schema must survive null AND absence, since
    /// agents already deployed in the field won't be updated.
    func testDecodesNullAndMissingArrays() throws {
        let nullArrays = #"""
        {"machineId":"pi","hostname":"raspberrypi","os":"Debian aarch64","kind":"linux",
         "agentVersion":"0.1.0","ts":1,
         "cpu":{"cores":4,"usagePercent":3,"loadAvg1":0.1},
         "memory":{"totalBytes":4294967296,"usedBytes":1073741824,"availableBytes":3221225472},
         "gpus":null,
         "llm":{"ollama":{"running":true,"models":null,"loaded":null}}}
        """#
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(nullArrays.utf8))
        XCTAssertEqual(m.hostname, "raspberrypi")
        XCTAssertTrue(m.gpus.isEmpty)                       // null → [], not a thrown error
        XCTAssertTrue(try XCTUnwrap(m.llm?.ollama).models.isEmpty)
        XCTAssertTrue(try XCTUnwrap(m.llm?.ollama).loaded.isEmpty)

        // The same payload with the array keys omitted entirely (an older/leaner agent).
        let missing = #"""
        {"machineId":"pi","hostname":"raspberrypi","os":"Debian aarch64","kind":"linux",
         "agentVersion":"0.1.0","ts":1,
         "cpu":{"cores":4,"usagePercent":3,"loadAvg1":0.1},
         "memory":{"totalBytes":4294967296,"usedBytes":1073741824,"availableBytes":3221225472}}
        """#
        let m2 = try JSONDecoder().decode(MachineMetrics.self, from: Data(missing.utf8))
        XCTAssertTrue(m2.gpus.isEmpty)
        XCTAssertNil(m2.llm)
    }

    /// A GPU whose `processes` arrive as null must not sink the payload either.
    func testDecodesGPUWithNullProcesses() throws {
        let json = #"{"machineId":"x","hostname":"h","os":"o","kind":"linux","agentVersion":"0.1.0","ts":1,"cpu":{"cores":8,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[{"index":0,"name":"RTX 3090","driver":"595","vramTotalBytes":1,"vramUsedBytes":0,"utilizationPercent":0,"temperatureC":40,"powerDrawW":35,"powerLimitW":390,"processes":null}]}"#
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertEqual(m.gpus.count, 1)
        XCTAssertTrue(try XCTUnwrap(m.gpus.first).processes.isEmpty)
    }

    /// Round-trip: what we encode must still be a real array, so tolerating null on the way in
    /// never leaks null on the way out.
    func testEncodesEmptyArraysAsArraysNotNull() throws {
        let m = try JSONDecoder().decode(MachineMetrics.self,
                                         from: Data(#"{"machineId":"x","hostname":"h","os":"o","kind":"linux","agentVersion":"0.1.0","ts":1,"cpu":{"cores":1,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":null}"#.utf8))
        let out = String(data: try JSONEncoder().encode(m), encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("\"gpus\":[]"), out)
        XCTAssertFalse(out.contains("\"gpus\":null"), out)
    }

    /// A machine with no NVIDIA GPU and no Ollama must still decode (empty gpus, nil llm).
    func testDecodesMinimalMachine() throws {
        let json = #"{"machineId":"x","hostname":"h","os":"o","kind":"linux","agentVersion":"0.1.0","ts":1,"cpu":{"cores":8,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[]}"#
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertTrue(m.gpus.isEmpty)
        XCTAssertNil(m.llm)
    }

    // Real capture from the Mac agent (v1.0.0) on an 8 GB M1 MacBook Air, trimmed to the fields
    // under test. wired+active+compressed == usedBytes, exactly as the kernel reports it.
    private let macJSON = #"""
    {
      "machineId": "E1AB9863-DA4D-5056-A1A1-B2B2C3C3D4D4",
      "hostname": "MacBook Air M1", "os": "macOS 26.3.1", "kind": "mac",
      "agentVersion": "1.0.0", "ts": 1784645251558,
      "cpu": { "cores": 8, "usagePercent": 25.748414131734563, "loadAvg1": 1.89990234375,
               "eUsagePercent": 51.127819548872175, "pUsagePercent": 0.3690087145969499,
               "eFreqMHz": 977.488203541938, "pFreqMHz": 0, "eCores": 4, "pCores": 4 },
      "memory": { "totalBytes": 8589934592, "usedBytes": 5963661312, "availableBytes": 2626273280,
                  "wiredBytes": 1483997184, "activeBytes": 1964195840, "compressedBytes": 2515468288,
                  "appMemoryBytes": 2240577536, "cachedFilesBytes": 1700265984,
                  "swapUsedBytes": 115605504, "swapTotalBytes": 1073741824, "pressure": "normal" },
      "gpus": [ { "index": 0, "name": "Apple M1", "driver": "",
                  "vramTotalBytes": 8589934592, "vramUsedBytes": 107374182,
                  "utilizationPercent": 0, "temperatureC": 30, "powerDrawW": 0, "powerLimitW": 0,
                  "processes": [] } ],
      "apple": { "chip": "Apple M1", "aneWatts": 0, "anePeakWatts": 1.360639149381132,
                 "mediaGBs": 0, "mediaPeakGBs": 2, "socWatts": 0.4,
                 "power": { "cpuWatts": 0.3, "eCpuWatts": 0.2, "pCpuWatts": 0.1,
                            "gpuWatts": 0, "aneWatts": 0, "dramWatts": 0.05 },
                 "bandwidth": { "cpuGBs": 1, "gpuGBs": 0, "mediaGBs": 0, "otherGBs": 0,
                                "totalGBs": 1.2, "isEstimated": false, "totalPeakGBs": 76.78 },
                 "fanRPMs": [] }
    }
    """#

    /// The Apple VM split must survive the wire AND land in the synthesized snapshot: the remote
    /// Memory card derives used / free / pressure% from wired+active+compressed. Before these were
    /// transmitted the card printed 0.0 GB for Wired/Compressed/App/Cached/Swap — an instrument must
    /// never invent numbers, so this pins the whole chain.
    func testMacMemoryBreakdownDecodesAndMapsToSnapshot() throws {
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(macJSON.utf8))
        XCTAssertEqual(m.kind, "mac")
        XCTAssertEqual(m.memory.wiredBytes, 1483997184)
        XCTAssertEqual(m.memory.pressure, "normal")
        XCTAssertEqual(try XCTUnwrap(m.apple?.bandwidth.totalPeakGBs), 76.78, accuracy: 1e-9)

        let (s, topo) = m.toDashboardSnapshot()
        XCTAssertEqual(s.memory.totalBytes, 8589934592)
        XCTAssertEqual(s.memory.wiredBytes, 1483997184)
        XCTAssertEqual(s.memory.activeBytes, 1964195840)
        XCTAssertEqual(s.memory.compressedBytes, 2515468288)
        XCTAssertEqual(s.memory.appMemoryBytes, 2240577536)
        XCTAssertEqual(s.memory.cachedFilesBytes, 1700265984)
        XCTAssertEqual(s.memory.swapUsedBytes, 115605504)
        XCTAssertEqual(s.memory.swapTotalBytes, 1073741824)
        XCTAssertEqual(s.memory.pressure, .normal)
        // Everything the card actually prints falls out of the three-way split:
        XCTAssertEqual(s.memory.usedBytes, 5963661312)                       // wired+active+compressed
        XCTAssertEqual(s.memory.freeBytes, 2626273280)                       // total-used
        XCTAssertEqual(s.memory.pressurePercent, 46.56, accuracy: 0.05)      // (wired+compressed)/total
        XCTAssertEqual(topo.eCoreCount, 4)
        XCTAssertEqual(topo.pCoreCount, 4)
    }

    /// A pre-1.1 Mac agent omits the split. The stacked bar must still render (used→active) instead
    /// of collapsing to an empty stack.
    func testMacWithoutMemoryBreakdownFallsBackToUsedAsActive() throws {
        let json = #"{"machineId":"x","hostname":"old","os":"macOS 15","kind":"mac","agentVersion":"1.0.0","ts":1,"cpu":{"cores":8,"usagePercent":1,"loadAvg1":0},"memory":{"totalBytes":8589934592,"usedBytes":4294967296,"availableBytes":4294967296},"gpus":[]}"#
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertNil(m.memory.wiredBytes)
        let (s, _) = m.toDashboardSnapshot()
        XCTAssertEqual(s.memory.activeBytes, 4294967296)   // used→active so the bar isn't blank
        XCTAssertEqual(s.memory.wiredBytes, 0)
        XCTAssertEqual(s.memory.compressedBytes, 0)
    }
}
