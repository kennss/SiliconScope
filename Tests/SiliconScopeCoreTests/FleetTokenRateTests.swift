//
//  File:      FleetTokenRateTests.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the wire contract for a remote machine's decode rate (#37). The JSON here is
//             VERBATIM from the Go agent running on this Mac against LM Studio — not hand-written —
//             so a change on either side of the boundary breaks this test rather than the Fleet view.
//  Notes:     The absent case matters as much as the present one: Ollama publishes no server-side
//             rate, and decoding that into 0 tok/s would put a fabricated number on screen. `rate`
//             must stay nil, and an older agent that has never heard of the field must still decode.
//
import XCTest
@testable import SiliconScopeCore

final class FleetTokenRateTests: XCTestCase {

    private func decode(_ json: String) throws -> MachineMetrics {
        try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
    }

    /// A machine with no LLM block at all — the shape every pre-1.1 agent sends.
    private let bare = """
    {"machineId":"m1","hostname":"box","os":"linux","kind":"linux","agentVersion":"1.0.1",
     "ts":1786334963000,"cpu":{"cores":8,"usagePercent":12,"loadAvg1":0.4},
     "memory":{"totalBytes":100,"usedBytes":40,"availableBytes":60},"gpus":[]}
    """

    /// Verbatim from `sscope-agent-mac --serve` after one LM Studio prediction.
    private let withRate = """
    {"machineId":"m1","hostname":"box","os":"macOS","kind":"mac","agentVersion":"1.1.0",
     "ts":1786334963200,"cpu":{"cores":10,"usagePercent":9,"loadAvg1":1.2},
     "memory":{"totalBytes":100,"usedBytes":40,"availableBytes":60},"gpus":[],
     "llm":{"ollama":{"running":true,"models":[],"loaded":[]},
            "rate":{"tokensPerSec":28.189130271367365,"source":"lmstudio",
                    "model":"google/gemma-4-12b","measuredAt":1786334963113,"ttftSec":0.284}}}
    """

    func testRealAgentPayloadDecodes() throws {
        let m = try decode(withRate)
        let r = try XCTUnwrap(m.llm?.rate)
        XCTAssertEqual(r.tokensPerSec, 28.189130271367365, accuracy: 1e-9)
        XCTAssertEqual(r.source, "lmstudio")
        XCTAssertEqual(r.sourceLabel, "LM Studio")
        XCTAssertEqual(r.model, "google/gemma-4-12b")
        XCTAssertEqual(r.ttftSec ?? 0, 0.284, accuracy: 1e-9)
    }

    /// An agent that never sends a rate must not produce one. A measured 0 tok/s and "no runtime
    /// reports a rate" are different facts, and only one of them belongs on screen.
    func testAbsentRateStaysNil() throws {
        XCTAssertNil(try decode(bare).llm?.rate)
    }

    /// The LLM block can exist without a rate (Ollama only) — that must not fail the whole decode,
    /// which is the failure mode that once removed a machine from the fleet entirely (#33).
    func testOllamaOnlyStillDecodes() throws {
        let json = """
        {"machineId":"m1","hostname":"box","os":"linux","kind":"linux","agentVersion":"1.0.1",
         "ts":1,"cpu":{"cores":8,"usagePercent":1,"loadAvg1":0},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[],
         "llm":{"ollama":{"running":true,"models":[],"loaded":[]}}}
        """
        let m = try decode(json)
        XCTAssertNotNil(m.llm?.ollama)
        XCTAssertNil(m.llm?.rate)
    }

    /// A rate with no runtime block of its own — llama.cpp answers on /metrics while Ollama is not
    /// installed at all, which is the common shape on a dedicated inference box.
    func testRateWithoutOllamaDecodes() throws {
        let json = """
        {"machineId":"m1","hostname":"box","os":"linux","kind":"linux","agentVersion":"1.1.0",
         "ts":1,"cpu":{"cores":8,"usagePercent":1,"loadAvg1":0},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[],
         "llm":{"rate":{"tokensPerSec":41.5,"source":"llama.cpp","measuredAt":1786334963113}}}
        """
        let r = try XCTUnwrap(try decode(json).llm?.rate)
        XCTAssertNil(try decode(json).llm?.ollama)
        XCTAssertEqual(r.sourceLabel, "llama.cpp")
        XCTAssertNil(r.model)
        XCTAssertNil(r.ttftSec)
    }

    /// Age drives whether the UI presents the number as current. It must be computed from the
    /// measurement's own timestamp, never from when the sample happened to arrive.
    func testAgeComesFromTheMeasurementNotTheSample() throws {
        let tenMinutesAgo = Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let r = FleetTokenRate(tokensPerSec: 30, source: "lmstudio", model: nil,
                               measuredAt: tenMinutesAgo, ttftSec: nil)
        XCTAssertEqual(r.age, 600, accuracy: 5)
    }

    /// An unknown source must still render as something, rather than vanishing from the row.
    func testUnknownSourceFallsBackToItsRawName() {
        let r = FleetTokenRate(tokensPerSec: 1, source: "vllm", model: nil, measuredAt: 0, ttftSec: nil)
        XCTAssertEqual(r.sourceLabel, "vllm")
    }
}
