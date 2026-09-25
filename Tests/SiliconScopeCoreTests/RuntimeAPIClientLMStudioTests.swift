//
//  File:      RuntimeAPIClientLMStudioTests.swift
//  Created:   2026-09-25
//  Updated:   2026-09-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in what counts as a LOADED LM Studio model. The same over-report as oMLX's
//             (#66) was waiting on this path: a missing `state` read as loaded, and a fallback
//             that took the OpenAI `/v1/models` list — which LM Studio documents may be every
//             downloaded model under JIT loading — as the resident set.
//  Notes:     The v1 fixture is LM Studio's documented `GET /api/v1/models` example, trimmed to
//             the fields read here (unknown keys are ignored by Codable). The v0 fixture follows
//             the documented `GET /api/v0/models` shape.
//
import XCTest
@testable import SiliconScopeCore

final class RuntimeAPIClientLMStudioTests: XCTestCase {

    private static let v1JSON = """
    {
      "models": [
        { "type": "llm", "key": "google/gemma-4-26b-a4b", "params_string": "26B-A4B",
          "quantization": { "name": "Q4_K_M", "bits_per_weight": 4 },
          "size_bytes": 17990911801, "max_context_length": 262144,
          "loaded_instances": [
            { "id": "google/gemma-4-26b-a4b", "config": { "context_length": 4096, "parallel": 4 } }
          ] },
        { "type": "llm", "key": "deepseek-r1", "params_string": "671B",
          "quantization": { "name": "Q4_K_M", "bits_per_weight": 4 },
          "size_bytes": 40492610355, "max_context_length": 131072, "loaded_instances": [] },
        { "type": "embedding", "key": "text-embedding-nomic-embed-text-v1.5-embedding",
          "quantization": { "name": "F16", "bits_per_weight": 16 },
          "size_bytes": 274290560, "params_string": null, "max_context_length": 2048,
          "loaded_instances": [] }
      ]
    }
    """

    private func v1(_ json: String) throws -> [RuntimeModelInfo] {
        RuntimeAPIClient.lmStudioLoadedModels(
            try JSONDecoder().decode(RuntimeAPIClient.LMSModelsV1.self, from: Data(json.utf8)))
    }

    private func v0(_ json: String) throws -> [RuntimeModelInfo] {
        RuntimeAPIClient.lmStudioLoadedModels(
            try JSONDecoder().decode(RuntimeAPIClient.LMSModels.self, from: Data(json.utf8)))
    }

    /// Of three downloaded models, one is loaded — and only that one is reported.
    func testV1ReportsOnlyModelsWithLoadedInstances() throws {
        let loaded = try v1(Self.v1JSON)
        XCTAssertEqual(loaded.map(\.name), ["google/gemma-4-26b-a4b"])
        XCTAssertEqual(loaded.first?.quantization, "Q4_K_M")
        XCTAssertEqual(loaded.first?.parameterSize, "26B-A4B")
        XCTAssertEqual(loaded.first?.contextLength, 4096, "the context it was LOADED with, not the model's maximum")
    }

    /// Nothing loaded is an empty list — "no model loaded" is then the truth.
    func testV1WithNothingLoadedIsEmpty() throws {
        XCTAssertEqual(try v1(#"{"models":[{"key":"deepseek-r1","loaded_instances":[]}]}"#).count, 0)
        XCTAssertEqual(try v1(#"{"models":[{"key":"deepseek-r1"}]}"#).count, 0, "no instances field is not loaded")
    }

    /// Two copies of one model are two resident instances, each under its own identifier.
    func testV1ReportsEachLoadedInstance() throws {
        let json = #"{"models":[{"key":"qwen3-8b","loaded_instances":[{"id":"qwen3-8b"},{"id":"qwen3-8b:2"}]}]}"#
        XCTAssertEqual(try v1(json).map(\.name), ["qwen3-8b", "qwen3-8b:2"])
    }

    /// Sizes stay unset: a size with no VRAM figure renders as "100% CPU" for a GPU-resident model.
    func testV1LeavesSizesUnset() throws {
        XCTAssertEqual(try v1(Self.v1JSON).first?.sizeBytes, 0)
        XCTAssertNil(try v1(Self.v1JSON).first?.processorLabel)
    }

    /// v0: only an explicit "loaded". A missing state used to count as loaded.
    func testV0CountsOnlyAnExplicitLoadedState() throws {
        let json = """
        {"object":"list","data":[
          {"id":"google/gemma-4-12b","state":"loaded","quantization":"Q4_K_M","loaded_context_length":8192,"max_context_length":131072},
          {"id":"qwen2-vl-7b-instruct","state":"not-loaded","max_context_length":32768},
          {"id":"mystery-model"}
        ]}
        """
        let loaded = try v0(json)
        XCTAssertEqual(loaded.map(\.name), ["google/gemma-4-12b"])
        XCTAssertEqual(loaded.first?.contextLength, 8192)
    }
}
