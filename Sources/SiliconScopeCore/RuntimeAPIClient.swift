//
//  File:      RuntimeAPIClient.swift
//  Created:   2026-06-14
//  Updated:   2026-09-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Opt-in probes of local AI runtime HTTP APIs, keyed by the detected runtime.
//             Ollama /api/ps gives the authoritative model size + GPU/CPU split (size_vram
//             / size); llama.cpp /metrics gives real tokens/sec; LM Studio reports the
//             loaded instances (REST v1, else v0 state) + quant + context; exo/Rapid-MLX/mlx-dspark/MTPLX/DS4 expose an
//             OpenAI-compatible /v1/models, while oMLX reports per-model loaded state on
//             /v1/models/status. All sudoless, localhost-only (LocalHTTP).
//  Notes:     Every JSON field is optional (version drift tolerant). A non-answer maps to
//             runningNoServer / apiNotApplicable / unreachable — never a crash. tokens/sec
//             is left nil unless the runtime actually reports it.
//             The port is resolved by the caller through `AIRuntimeSample.apiPort(for:configured:)`
//             — this file only knows what to ask, never where.
//
import Foundation

public struct RuntimeAPIClient: Sendable {
    private let http = LocalHTTP()
    public init() {}

    /// Probes the runtime that feature ① identified as primary, at `port` — pass
    /// `AIRuntimeSample.apiPort(for:configured:)`. A nil port means there is nothing to ask: a
    /// llama.cpp seen without a server (#53), or a runtime with no API of its own.
    public func probe(kind: AIRuntimeKind?, port: Int?, omlxApiKey: String = "") async -> RuntimeAPISample {
        guard let kind else { var s = RuntimeAPISample(); s.status = .unreachable; return s }
        guard let port else { var s = RuntimeAPISample(); s.status = .runningNoServer; return s }
        switch kind {
        case .ollama:    return await probeOllama(port: port)
        case .lmStudio:  return await probeLMStudio(port: port)
        case .llamaCpp:  return await probeLlamaCpp(port: port)
        case .rapidMLX:  return await probeOpenAI(port: port, apiKey: nil, source: .rapidMLX)
        case .exo:       return await probeOpenAI(port: port, apiKey: nil, source: .exo)       // cluster
        // oMLX gets its own probe: its /v1/models is the installed catalog (unloaded models
        // included, in id order), so the generic OpenAI path both over-reports and picks a
        // model by alphabet instead of by what is actually resident.
        case .omlx:      return await probeOMLX(port: port, apiKey: omlxApiKey)
        case .mlxDSpark: return await probeOpenAI(port: port, apiKey: nil, source: .mlxDSpark)
        // Both serve one model per process, so /v1/models lists exactly what is resident.
        case .mtplx:     return await probeOpenAI(port: port, apiKey: nil, source: .mtplx)
        case .ds4:       return await probeOpenAI(port: port, apiKey: nil, source: .ds4)
        case .mlx, .jan, .gpt4all, .vllm, .spectalo, .spectaling, .other:
            var s = RuntimeAPISample(); s.status = .runningNoServer; return s
        }
    }

    // MARK: - Ollama (127.0.0.1:11434 /api/ps)

    private func probeOllama(port: Int) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = .ollama
        guard let data = try? await http.get(port: port, path: "/api/ps") else {
            s.status = .runningNoServer; return s
        }
        guard let ps = try? JSONDecoder().decode(OllamaPS.self, from: data) else {
            s.status = .unreachable; return s
        }
        // Empty models => running but nothing loaded (distinct from unreachable).
        s.status = .ok
        s.lastUpdated = Date()
        s.loadedModels = (ps.models ?? []).map { m in
            RuntimeModelInfo(
                name: m.name ?? m.model ?? "model",
                sizeBytes: m.size ?? 0,
                sizeVRAMBytes: m.size_vram ?? 0,
                parameterSize: m.details?.parameter_size,
                quantization: m.details?.quantization_level,
                contextLength: m.context_length
            )
        }
        return s
    }

    // MARK: - LM Studio (127.0.0.1:1234; REST /api/v1, then /api/v0)

    /// LM Studio's loaded set, from the only two endpoints that say what is resident.
    ///
    /// ⚠️ Its OpenAI-compatible `/v1/models` is NOT one of them. LM Studio documents that it "may
    /// include all downloaded models when Just-In-Time loading is enabled" — the catalog, like
    /// oMLX's (#66), so reading it as the loaded set names a model that is on disk and resident
    /// nowhere. With neither REST API answering, the honest result is "no answer", not a list.
    private func probeLMStudio(port: Int) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = .lmStudio
        // v1 REST (LM Studio 0.4+): each model lists its loaded instances.
        if let data = try? await http.get(port: port, path: "/api/v1/models"),
           let resp = try? JSONDecoder().decode(LMSModelsV1.self, from: data), resp.models != nil {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = Self.lmStudioLoadedModels(resp)
            return s
        }
        // v0 REST (superseded, still served): a per-model `state`.
        if let data = try? await http.get(port: port, path: "/api/v0/models"),
           let resp = try? JSONDecoder().decode(LMSModels.self, from: data), resp.data != nil {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = Self.lmStudioLoadedModels(resp)
            return s
        }
        s.status = .runningNoServer
        return s
    }

    /// v1: a model is loaded when it has loaded instances, and each instance is one resident copy
    /// under its own identifier — the name the OpenAI endpoints accept, so the benchmark can use it.
    ///
    /// Sizes stay unset, as for oMLX: `size_bytes` with no VRAM figure makes `processorLabel` read
    /// "100% CPU" for a model LM Studio runs on the GPU.
    static func lmStudioLoadedModels(_ resp: LMSModelsV1) -> [RuntimeModelInfo] {
        (resp.models ?? []).flatMap { m in
            (m.loaded_instances ?? []).map { inst in
                RuntimeModelInfo(name: inst.id, sizeBytes: 0, sizeVRAMBytes: 0,
                                 parameterSize: m.params_string, quantization: m.quantization?.name,
                                 contextLength: inst.config?.context_length ?? m.max_context_length)
            }
        }
    }

    /// v0: only an explicit "loaded" counts. A missing state is not evidence of residency —
    /// defaulting it to loaded is the assumption that over-reported oMLX (#66).
    static func lmStudioLoadedModels(_ resp: LMSModels) -> [RuntimeModelInfo] {
        (resp.data ?? [])
            .filter { $0.state == "loaded" }
            .map { m in
                RuntimeModelInfo(name: m.id, sizeBytes: 0, sizeVRAMBytes: 0,
                                 parameterSize: nil, quantization: m.quantization,
                                 contextLength: m.loaded_context_length ?? m.max_context_length)
            }
    }

    // MARK: - Generic OpenAI-compatible server (Rapid-MLX :8000, etc.)

    private func probeOpenAI(port: Int, apiKey: String?, source: RuntimeAPISample.Source) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = source
        var headers: [String: String] = [:]
        if let apiKey = apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if let data = try? await http.get(port: port, path: "/v1/models", headers: headers),
           let resp = try? JSONDecoder().decode(OpenAIModels.self, from: data) {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = (resp.data ?? []).map {
                RuntimeModelInfo(name: $0.id, sizeBytes: 0, sizeVRAMBytes: 0,
                                 parameterSize: nil, quantization: nil, contextLength: nil)
            }
            return s
        }
        s.status = .runningNoServer
        return s
    }

    // MARK: - oMLX (127.0.0.1:8000; /v1/models/status carries the real per-model loaded flag)

    /// oMLX's `/v1/models` lists every *installed* model — unloaded ones included, in
    /// case-sensitive id order — so reading it as "loaded" marks the whole catalog resident
    /// and makes `primaryModel` whatever id sorts first (`DeepSeek…` before `gemma…`),
    /// independently of what the user actually loaded or switched to.
    /// `/v1/models/status` carries an authoritative `loaded` boolean per model; `/api/status`
    /// names the loaded set on builds that predate it.
    private func probeOMLX(port: Int, apiKey: String) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = .omlx
        var headers: [String: String] = [:]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if let data = try? await http.get(port: port, path: "/v1/models/status", headers: headers),
           let resp = try? JSONDecoder().decode(OMLXModelStatus.self, from: data) {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = Self.omlxLoadedModels(resp.models)
            return s
        }
        if let data = try? await http.get(port: port, path: "/api/status", headers: headers),
           let resp = try? JSONDecoder().decode(OMLXStatus.self, from: data) {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = (resp.loaded_models ?? []).map {
                RuntimeModelInfo(name: $0, sizeBytes: 0, sizeVRAMBytes: 0,
                                 parameterSize: nil, quantization: nil, contextLength: nil)
            }
            return s
        }
        s.status = .runningNoServer
        return s
    }

    /// Keeps only what oMLX reports as actually resident, most-recently-used first, so
    /// `primaryModel` is the model the user has been working with rather than a catalog
    /// entry. A model whose `loaded` flag is absent is NOT assumed loaded — that assumption
    /// is precisely the over-reporting this guards against. `last_access == nil` sorts last.
    static func omlxLoadedModels(_ models: [OMLXModelStatus.Model]?) -> [RuntimeModelInfo] {
        (models ?? [])
            .filter { $0.loaded == true }
            .sorted { ($0.last_access ?? -Double.infinity) > ($1.last_access ?? -Double.infinity) }
            .map {
                RuntimeModelInfo(name: $0.id, sizeBytes: 0, sizeVRAMBytes: 0,
                                 parameterSize: nil, quantization: nil,
                                 contextLength: $0.max_context_window ?? $0.model_context_length)
            }
    }

    // MARK: - llama.cpp server (/health, /metrics, /props)

    private func probeLlamaCpp(port: Int) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = .llamaCpp
        guard (try? await http.get(port: port, path: "/health")) != nil else {
            s.status = .apiNotApplicable; return s     // bare CLI, no server
        }
        s.status = .ok; s.lastUpdated = Date()
        if let data = try? await http.get(port: port, path: "/metrics"),
           let text = String(data: data, encoding: .utf8) {
            s.tokensPerSec = Self.parseMetric(text, key: "llamacpp:predicted_tokens_seconds")
        }
        if let data = try? await http.get(port: port, path: "/props"),
           let props = try? JSONDecoder().decode(LlamaProps.self, from: data) {
            let name = props.model_path.map { ($0 as NSString).lastPathComponent } ?? "model"
            s.loadedModels = [RuntimeModelInfo(name: name, sizeBytes: 0, sizeVRAMBytes: 0,
                                               parameterSize: nil, quantization: nil,
                                               contextLength: props.n_ctx)]
        }
        return s
    }

    /// Extracts a Prometheus metric value (`<key> <value>` line).
    static func parseMetric(_ text: String, key: String) -> Double? {
        for line in text.split(separator: "\n") where line.hasPrefix(key) {
            if let value = line.split(separator: " ").last, let v = Double(value), v > 0 { return v }
        }
        return nil
    }

    // MARK: - Codable (all optional — tolerant of version drift)

    private struct OllamaPS: Codable {
        let models: [Model]?
        struct Model: Codable {
            let name: String?; let model: String?
            let size: UInt64?; let size_vram: UInt64?; let context_length: Int?
            let details: Details?
        }
        struct Details: Codable { let parameter_size: String?; let quantization_level: String? }
    }

    /// LM Studio v1 REST `GET /api/v1/models`. Every field optional: a newer build that adds or
    /// drops one must not make the whole list unreadable.
    struct LMSModelsV1: Codable {
        let models: [Model]?
        struct Model: Codable {
            let key: String?
            let params_string: String?
            let quantization: Quantization?
            let max_context_length: Int?
            let loaded_instances: [Instance]?
        }
        struct Quantization: Codable { let name: String? }
        struct Instance: Codable {
            let id: String
            let config: Config?
            struct Config: Codable { let context_length: Int? }
        }
    }

    struct LMSModels: Codable {
        let data: [Model]?
        struct Model: Codable {
            let id: String
            let state: String?
            let quantization: String?
            let max_context_length: Int?
            let loaded_context_length: Int?
        }
    }

    private struct OpenAIModels: Codable {
        let data: [Model]?
        struct Model: Codable { let id: String }
    }

    /// Internal (not private) so the decoder contract is unit-testable.
    struct OMLXModelStatus: Codable {
        let models: [Model]?
        struct Model: Codable {
            let id: String
            let loaded: Bool?
            let is_loading: Bool?
            let last_access: Double?
            let model_context_length: Int?
            let max_context_window: Int?
        }
    }

    /// Fallback shape for oMLX builds without /v1/models/status.
    struct OMLXStatus: Codable { let loaded_models: [String]? }

    private struct LlamaProps: Codable {
        let model_path: String?
        let n_ctx: Int?
    }
}
