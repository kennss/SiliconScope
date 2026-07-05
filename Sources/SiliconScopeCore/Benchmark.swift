//
//  File:      Benchmark.swift
//  Created:   2026-06-18
//  Updated:   2026-06-18
//  Developer: Kennt Kim / Calida Lab
//  Overview:  On-demand local-LLM speed benchmark. Sends ONE short fixed generation to a
//             runtime's localhost API and measures decode tokens/sec — the honest way to
//             get tok/s from runtimes that don't expose it passively (Ollama ships its
//             embedded llama-server WITHOUT `--metrics`, so /metrics is 501; /slots carries
//             no decoded-token count). Pairs with average package power (measured by the
//             monitor during the run) to yield tokens-per-watt.
//  Notes:     Localhost-only (127.0.0.1), no proxy/cellular — nothing leaves the machine.
//             Ollama path is authoritative (eval_count / eval_duration from /api/generate);
//             the OpenAI-compatible path (LM Studio, llama.cpp server) times the wall clock
//             of a non-streamed /v1/chat/completions, so it also counts prefill + transport
//             (a slight under-estimate vs Ollama's pure decode figure).
//
import Foundation

/// One measurement: the decode rate plus the token count it was measured over.
public struct BenchmarkResult: Sendable, Equatable {
    public let tokensPerSec: Double          // decode (generation) rate
    public let tokenCount: Int               // tokens generated during the run
    public let promptTokensPerSec: Double?   // prefill rate (Ollama reports it; nil otherwise)

    public init(tokensPerSec: Double, tokenCount: Int, promptTokensPerSec: Double? = nil) {
        self.tokensPerSec = tokensPerSec
        self.tokenCount = tokenCount
        self.promptTokensPerSec = promptTokensPerSec
    }
}

/// A persisted per-model result (the "this model on this machine" log).
public struct BenchmarkRecord: Sendable, Equatable, Codable, Identifiable {
    public let model: String
    public let runtime: String        // AIRuntimeKind.displayName
    public let chip: String           // e.g. "Apple M1 Max"
    public let tokensPerSec: Double
    public let avgWatts: Double        // mean SoC package power during the run
    public let timestamp: Date

    /// Efficiency in tokens per watt-hour (the familiar battery unit): tok/s ÷ W × 3600.
    /// E.g. ~4,800 tok/Wh ⇒ a 70 Wh MacBook battery ≈ 340k tokens on a full charge.
    public var tokensPerWattHour: Double { avgWatts > 0 ? tokensPerSec / avgWatts * 3600 : 0 }
    public var id: String { "\(runtime)|\(model)|\(timestamp.timeIntervalSince1970)" }

    public init(model: String, runtime: String, chip: String,
                tokensPerSec: Double, avgWatts: Double, timestamp: Date) {
        self.model = model
        self.runtime = runtime
        self.chip = chip
        self.tokensPerSec = tokensPerSec
        self.avgWatts = avgWatts
        self.timestamp = timestamp
    }
}

public struct BenchmarkClient: Sendable {
    private let session: URLSession

    public init() {
        // Generation can take many seconds — unlike the fast passive probe, allow a long
        // request budget but still localhost-only with proxies/cellular disabled.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 180
        cfg.connectionProxyDictionary = [:]
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = false
        session = URLSession(configuration: cfg)
    }

    /// Fixed, deterministic prompt so repeat runs are comparable.
    private static let prompt = "Write three concise sentences explaining why the sky is blue."

    /// Runs one bounded generation and returns the decode rate, or nil on any failure.
    public func run(kind: AIRuntimeKind, port: Int, model: String, apiKey: String? = nil, numPredict: Int = 128) async -> BenchmarkResult? {
        switch kind {
        case .ollama: return await runOllama(port: port, model: model, numPredict: numPredict)
        default:      return await runOpenAI(port: port, model: model, apiKey: apiKey, numPredict: numPredict)
        }
    }

    // Ollama: /api/generate (non-stream) returns eval_count + eval_duration (ns) — the exact
    // decode rate, independent of prefill and transport.
    private func runOllama(port: Int, model: String, numPredict: Int) async -> BenchmarkResult? {
        let body: [String: Any] = [
            "model": model, "prompt": Self.prompt, "stream": false,
            "options": ["num_predict": numPredict, "temperature": 0],
        ]
        guard let data = try? await post(port: port, path: "/api/generate", body: body),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let evalCount = (obj["eval_count"] as? NSNumber)?.intValue,
              let evalDurNs = (obj["eval_duration"] as? NSNumber)?.doubleValue,
              evalCount > 0, evalDurNs > 0 else { return nil }
        let tps = Double(evalCount) / (evalDurNs / 1e9)
        var promptTps: Double?
        if let pc = (obj["prompt_eval_count"] as? NSNumber)?.intValue,
           let pd = (obj["prompt_eval_duration"] as? NSNumber)?.doubleValue, pc > 0, pd > 0 {
            promptTps = Double(pc) / (pd / 1e9)
        }
        return BenchmarkResult(tokensPerSec: tps, tokenCount: evalCount, promptTokensPerSec: promptTps)
    }

    // OpenAI-compatible (LM Studio, llama.cpp server): no pure decode timing, so time the
    // wall clock of a non-streamed completion and divide by completion_tokens.
    private func runOpenAI(port: Int, model: String, apiKey: String?, numPredict: Int) async -> BenchmarkResult? {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": Self.prompt]],
            "max_tokens": numPredict, "temperature": 0, "stream": false,
        ]
        let start = Date()
        guard let data = try? await post(port: port, path: "/v1/chat/completions", body: body, apiKey: apiKey) else { return nil }
        let elapsed = -start.timeIntervalSinceNow
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = obj["usage"] as? [String: Any],
              let completion = (usage["completion_tokens"] as? NSNumber)?.intValue,
              completion > 0, elapsed > 0 else { return nil }
        return BenchmarkResult(tokensPerSec: Double(completion) / elapsed, tokenCount: completion)
    }

    private func post(port: Int, path: String, body: [String: Any], apiKey: String? = nil) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw LocalHTTP.HTTPError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw LocalHTTP.HTTPError.badStatus(code) }
        return data
    }
}
