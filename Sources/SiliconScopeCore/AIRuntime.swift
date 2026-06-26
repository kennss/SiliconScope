//
//  File:      AIRuntime.swift
//  Created:   2026-06-14
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Catalog + identity for local AI runtimes (Ollama, llama.cpp, LM Studio,
//             MLX, Rapid-MLX, Jan, GPT4All, vLLM). Pure logic — no syscalls; consumes the
//             path/args that ProcessSampler already resolved.
//  Notes:     proc_name truncates to 15 chars, so the executable PATH is the primary
//             signal and BUNDLE identity overrides basename — the Ollama runner is a
//             llama-server child, so basename alone would misclassify it as llama.cpp.
//             Resolution is two-stage: bundle/well-known-dir first (authoritative), then
//             basename/args. argv is only present for AI-candidate basenames (gated read).
//
import Foundation

public enum AIRuntimeKind: String, Sendable, CaseIterable, Codable {
    case ollama, llamaCpp, lmStudio, mlx, rapidMLX, jan, gpt4all, vllm

    public var displayName: String {
        switch self {
        case .ollama:   return "Ollama"
        case .llamaCpp: return "llama.cpp"
        case .lmStudio: return "LM Studio"
        case .mlx:      return "MLX"
        case .rapidMLX: return "Rapid-MLX"
        case .jan:      return "Jan"
        case .gpt4all:  return "GPT4All"
        case .vllm:     return "vLLM"
        }
    }

    /// Classifies a process. Bundle/path identity wins over basename (basenames collide —
    /// e.g. Ollama's `llama-server` runner child). `args` is optional (populated only for
    /// AI-candidate basenames). Returns nil for non-AI processes and empty/denied paths.
    public static func match(path: String, name: String, args: String?) -> AIRuntimeKind? {
        let p = path
        let a = args ?? ""

        // Stage 1 — bundle / well-known-dir identity (authoritative).
        if p.contains("/Ollama.app/") || p.contains("/.ollama/") || a.contains("/.ollama/") { return .ollama }
        if p.contains("/LM Studio.app/") { return .lmStudio }
        if p.contains("/Jan.app/") || p.contains("/jan/") { return .jan }
        if p.contains("/GPT4All.app/") || p.contains("/gpt4all/") { return .gpt4all }

        // Stage 2 — basename / args (only reached when Stage 1 found nothing).
        let base = (p as NSString).lastPathComponent
        // Rapid-MLX (rapid-mlx / rapid_mlx) — checked before the generic MLX match since the
        // OpenAI-compatible server is a distinct runtime (port 8000), not bare mlx_lm.
        if base == "rapid-mlx" || p.contains("rapid-mlx") || p.contains("rapid_mlx")
            || a.contains("rapid-mlx") || a.contains("rapid_mlx") { return .rapidMLX }
        if ["llama-server", "llama-cli", "llama-bench"].contains(base) { return .llamaCpp }
        if a.contains("mlx_lm.server") || a.contains("mlx_lm.generate") || a.contains("mlx_lm") { return .mlx }
        if base == "lms" || p.contains("LM Studio") || a.contains("LM Studio") { return .lmStudio }
        if a.contains("vllm") || p.contains("vllm") { return .vllm }

        return nil
    }

    /// Parses an embedded HTTP port from argv (e.g. the Ollama runner's `--port N` /
    /// `--port=N`). Returns nil when absent.
    public static func embeddedPort(args: String?) -> Int? {
        guard let args else { return nil }
        let tokens = args.split(separator: " ").map(String.init)
        for (i, t) in tokens.enumerated() {
            if t == "--port", i + 1 < tokens.count, let port = Int(tokens[i + 1]) { return port }
            if t.hasPrefix("--port="), let port = Int(t.dropFirst("--port=".count)) { return port }
        }
        return nil
    }
}
