//
//  File:      RuntimeAPIClientOMLXTests.swift
//  Created:   2026-09-19
//  Updated:   2026-09-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Regression tests for the oMLX loaded-model mapping. oMLX's /v1/models is the
//             catalog of *installed* models — unloaded ones included, in case-sensitive id
//             order — so treating it as the loaded set marked the whole catalog resident and
//             made primaryModel whichever id sorted first. That is why a machine running
//             Gemma still displayed "DeepSeek-R1-Distill-Qwen-14B-4bit" (D < Q < T < g).
//  Notes:     The fixture is a SUBSET of a real oMLX 0.6.4 GET /v1/models/status response —
//             keys and values verbatim, unrelated per-model keys omitted. Unknown keys are
//             ignored by Codable, so decoding the full payload behaves identically.
//
import XCTest
@testable import SiliconScopeCore

final class RuntimeAPIClientOMLXTests: XCTestCase {

    /// Real capture: DeepSeek was accessed after Gemma (which was loaded at 20:26 for a
    /// benchmark queue), and two of the four catalog entries were not resident at all.
    private static let liveStatusJSON = """
    {
      "final_ceiling": 41678260632,
      "current_model_memory": 23918193640,
      "model_count": 4,
      "loaded_count": 2,
      "models": [
        { "id": "DeepSeek-R1-Distill-Qwen-14B-4bit", "loaded": true, "is_loading": false,
          "last_access": 1789869492.316767, "model_context_length": 131072,
          "max_context_window": 131072 },
        { "id": "Qwen3.8-27B-Ternary-Bonsai-2-DFlash2-MLX", "loaded": false, "is_loading": false,
          "last_access": null, "model_context_length": 262144, "max_context_window": 262144 },
        { "id": "Ternary-Bonsai-2-27B-mlx-2bit", "loaded": false, "is_loading": false,
          "last_access": null, "model_context_length": 262144, "max_context_window": 262144 },
        { "id": "gemma-4-26B-A4B-it-QAT-MLX-4bit", "loaded": true, "is_loading": false,
          "last_access": 1789867573.023005, "model_context_length": 262144,
          "max_context_window": 262144 }
      ]
    }
    """

    private func status(_ json: String) throws -> RuntimeAPIClient.OMLXModelStatus {
        try JSONDecoder().decode(RuntimeAPIClient.OMLXModelStatus.self, from: Data(json.utf8))
    }

    // MARK: - The reported bug

    /// The catalog lists four models; only two are resident. All four must NOT come back.
    func testLiveCaptureKeepsOnlyResidentModels() throws {
        let models = RuntimeAPIClient.omlxLoadedModels(try status(Self.liveStatusJSON).models)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(Set(models.map(\.name)),
                       ["DeepSeek-R1-Distill-Qwen-14B-4bit",
                        "gemma-4-26B-A4B-it-QAT-MLX-4bit"])
        XCTAssertFalse(models.contains { $0.name.contains("Ternary") })
    }

    /// The exact user-visible symptom: Gemma is the only resident model, yet an unloaded
    /// DeepSeek entry sits first in /v1/models. The label must follow residency, not order.
    func testFirstCatalogEntryThatIsNotResidentNeverBecomesTheModel() throws {
        let json = """
        { "models": [
          { "id": "DeepSeek-R1-Distill-Qwen-14B-4bit", "loaded": false, "last_access": null },
          { "id": "gemma-4-26B-A4B-it-QAT-MLX-4bit", "loaded": true,
            "last_access": 1789867573.023005 }
        ] }
        """
        let models = RuntimeAPIClient.omlxLoadedModels(try status(json).models)
        XCTAssertEqual(models.map(\.name), ["gemma-4-26B-A4B-it-QAT-MLX-4bit"])
    }

    /// An absent `loaded` flag must not be read as loaded — that `?? "loaded"` assumption is
    /// the same over-reporting shape as the LM Studio path.
    func testMissingLoadedFlagIsNotTreatedAsLoaded() throws {
        let json = """
        { "models": [ { "id": "mystery-model" } ] }
        """
        XCTAssertTrue(RuntimeAPIClient.omlxLoadedModels(try status(json).models).isEmpty)
    }

    // MARK: - Ordering

    /// primaryModel should be the model the user touched last, so the label tracks what they
    /// are working with instead of an alphabetical accident.
    func testMostRecentlyUsedResidentModelIsFirst() throws {
        let models = RuntimeAPIClient.omlxLoadedModels(try status(Self.liveStatusJSON).models)
        XCTAssertEqual(models.first?.name, "DeepSeek-R1-Distill-Qwen-14B-4bit")
    }

    func testResidentModelWithoutLastAccessSortsLastButIsKept() throws {
        let json = """
        { "models": [
          { "id": "never-accessed", "loaded": true, "last_access": null },
          { "id": "recent", "loaded": true, "last_access": 1700000000.0 }
        ] }
        """
        let models = RuntimeAPIClient.omlxLoadedModels(try status(json).models)
        XCTAssertEqual(models.map(\.name), ["recent", "never-accessed"])
    }

    // MARK: - Tolerance

    func testEmptyAndMissingModelListsDoNotCrash() throws {
        XCTAssertTrue(RuntimeAPIClient.omlxLoadedModels(nil).isEmpty)
        XCTAssertTrue(RuntimeAPIClient.omlxLoadedModels(try status(#"{ "models": [] }"#).models).isEmpty)
    }

    /// `/api/status` fallback shape (builds predating /v1/models/status).
    func testFallbackStatusDecodesLoadedModelNames() throws {
        let json = #"{ "status": "ok", "models_loaded": 2, "loaded_models": ["a", "b"] }"#
        let resp = try JSONDecoder().decode(RuntimeAPIClient.OMLXStatus.self, from: Data(json.utf8))
        XCTAssertEqual(resp.loaded_models, ["a", "b"])
    }

    /// Context window is display-only, and oMLX reports the effective window separately.
    func testContextWindowPrefersMaxContextWindow() throws {
        let json = """
        { "models": [ { "id": "m", "loaded": true, "model_context_length": 8192,
                        "max_context_window": 262144 } ] }
        """
        let models = RuntimeAPIClient.omlxLoadedModels(try status(json).models)
        XCTAssertEqual(models.first?.contextLength, 262144)
    }

    /// Sizes are deliberately left unset: a non-zero sizeBytes with no VRAM figure would make
    /// processorLabel report "100% CPU" for a GPU-resident MLX model.
    func testLeavesSizesUnsetToAvoidFabricatingAnOffloadSplit() throws {
        let models = RuntimeAPIClient.omlxLoadedModels(try status(Self.liveStatusJSON).models)
        XCTAssertTrue(models.allSatisfy { $0.sizeBytes == 0 })
        XCTAssertTrue(models.allSatisfy { $0.processorLabel == nil })
    }
}
