//
//  File:      RuntimeAPIClient.swift
//  Created:   2026-06-14
//  Updated:   2026-07-02
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Opt-in probes of local AI runtime HTTP APIs, keyed by the detected runtime.
//             Ollama /api/ps gives the authoritative model size + GPU/CPU split (size_vram
//             / size); llama.cpp /metrics gives real tokens/sec; LM Studio reports the
//             loaded model id + quant + context; exo/Rapid-MLX expose an OpenAI-compatible
//             /v1/models. All sudoless, localhost-only (LocalHTTP).
//  Notes:     Every JSON field is optional (version drift tolerant). A non-answer maps to
//             runningNoServer / apiNotApplicable / unreachable — never a crash. tokens/sec
//             is left nil unless the runtime actually reports it.
//
import Foundation

public struct RuntimeAPIClient: Sendable {
    private let http = LocalHTTP()
    public init() {}

    /// Probes the runtime that feature ① identified as primary.
    public func probe(primaryKind: AIRuntimeKind?, ollamaEmbeddedPort: Int?,
                      ollamaPort: Int, lmStudioPort: Int) async -> RuntimeAPISample {
        switch primaryKind {
        case .ollama:   return await probeOllama(port: ollamaPort)
        case .lmStudio: return await probeLMStudio(port: lmStudioPort)
        case .llamaCpp: return await probeLlamaCpp(port: ollamaEmbeddedPort ?? 8080)
        case .rapidMLX: return await probeOpenAI(port: 8000, source: .rapidMLX)   // OpenAI-compatible
        case .exo:      return await probeOpenAI(port: 52415, source: .exo)       // OpenAI-compatible cluster
        case .some:                                   // mlx / jan / gpt4all / vllm
            var s = RuntimeAPISample(); s.status = .runningNoServer; return s
        case .none:
            var s = RuntimeAPISample(); s.status = .unreachable; return s
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

    // MARK: - LM Studio (127.0.0.1:1234; REST /api/v0 then OpenAI /v1)

    private func probeLMStudio(port: Int) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = .lmStudio
        if let data = try? await http.get(port: port, path: "/api/v0/models"),
           let resp = try? JSONDecoder().decode(LMSModels.self, from: data) {
            s.status = .ok; s.lastUpdated = Date()
            s.loadedModels = (resp.data ?? [])
                .filter { ($0.state ?? "loaded") == "loaded" }
                .map { m in
                    RuntimeModelInfo(name: m.id, sizeBytes: 0, sizeVRAMBytes: 0,
                                     parameterSize: nil, quantization: m.quantization,
                                     contextLength: m.loaded_context_length ?? m.max_context_length)
                }
            return s
        }
        if let data = try? await http.get(port: port, path: "/v1/models"),
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

    // MARK: - Generic OpenAI-compatible server (Rapid-MLX :8000, etc.)

    private func probeOpenAI(port: Int, source: RuntimeAPISample.Source) async -> RuntimeAPISample {
        var s = RuntimeAPISample(); s.source = source
        if let data = try? await http.get(port: port, path: "/v1/models"),
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

    private struct LMSModels: Codable {
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

    private struct LlamaProps: Codable {
        let model_path: String?
        let n_ctx: Int?
    }
}
