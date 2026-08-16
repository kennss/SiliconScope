//
//  File:      AIRuntime.swift
//  Created:   2026-06-14
//  Updated:   2026-08-16
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Catalog + identity for local AI runtimes (Ollama, llama.cpp, LM Studio,
//             MLX, Rapid-MLX, mlx-dspark, Jan, GPT4All, vLLM, exo). Pure logic — no
//             syscalls; consumes the path/args that ProcessSampler already resolved.
//  Notes:     proc_name truncates to 15 chars, so the executable PATH is the primary
//             signal and BUNDLE identity overrides basename — the Ollama runner is a
//             llama-server child, so basename alone would misclassify it as llama.cpp.
//             Resolution is two-stage: bundle/well-known-dir first (authoritative), then
//             basename/args. argv is only present for AI-candidate basenames (gated read).
//
import Foundation

public enum AIRuntimeKind: String, Sendable, CaseIterable, Codable {
    case ollama, llamaCpp, lmStudio, mlx, rapidMLX, mlxDSpark, jan, gpt4all, vllm, exo, omlx
    /// On-device AI **apps** rather than model servers: they run Core ML / WhisperKit inference on
    /// the ANE and never open a port. Detected because the question this card answers is "what is
    /// driving the silicon", and an ASR app driving the Neural Engine is exactly that — indeed the
    /// workload SiliconScope was built to watch in the first place.
    case spectalo, spectaling
    /// An AI process a NEWER build recognised and this one does not. Decode-only: `match` never
    /// returns it. Without it, one unknown raw value fails the whole `SystemSnapshot` and takes a
    /// recording down with it — the same trap `GlyphMode` hit.
    case other

    public var displayName: String {
        switch self {
        case .ollama:   return "Ollama"
        case .llamaCpp: return "llama.cpp"
        case .lmStudio: return "LM Studio"
        case .mlx:      return "MLX"
        case .rapidMLX: return "Rapid-MLX"
        case .mlxDSpark: return "mlx-dspark"
        case .jan:      return "Jan"
        case .gpt4all:  return "GPT4All"
        case .vllm:     return "vLLM"
        case .exo:      return "exo"
        case .omlx:     return "oMLX"
        case .spectalo:   return "Spectalo"
        case .spectaling: return "SpectaLing"
        case .other:      return "AI runtime"
        }
    }

    /// Whether this runtime can expose a local HTTP API at all.
    ///
    /// The on-device apps cannot: they run Core ML in-process and never open a port, so telling
    /// their user to "start its local server" is advice for a thing that does not exist. A monitor
    /// that instructs is already past describing (instrument, not nanny) — instructing something
    /// impossible is worse.
    public var servesAPI: Bool {
        switch self {
        case .spectalo, .spectaling, .other: return false
        default:                             return true
        }
    }

    /// Tolerant decoding — an unrecognised runtime becomes `.other` instead of failing its
    /// container. Recordings carry this enum inside every frame's snapshot, so a value written by a
    /// newer build must not make the whole file unreadable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIRuntimeKind(rawValue: raw) ?? .other
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
        if p.contains("/Jan.app/") { return .jan }
        if p.contains("/GPT4All.app/") { return .gpt4all }
        if p.contains("/oMLX.app/") || p.contains("/omlx.app/") { return .omlx }
        // Calida Lab's own on-device AI apps. Bundle identity only — their executables are plain
        // names ("Spectalo", "SpectaLing") that a basename rule could collide with, and both ship
        // debug builds from DerivedData whose paths still carry the bundle.
        if p.contains("/Spectalo.app/") { return .spectalo }
        if p.contains("/SpectaLing.app/") { return .spectaling }

        // Stage 2 — basename / args (only reached when Stage 1 found nothing).
        let base = (p as NSString).lastPathComponent
        // Rapid-MLX (rapid-mlx / rapid_mlx) — checked before the generic MLX match since the
        // OpenAI-compatible server is a distinct runtime (port 8000), not bare mlx_lm.
        if base == "rapid-mlx" || p.contains("rapid-mlx") || p.contains("rapid_mlx")
            || a.contains("rapid-mlx") || a.contains("rapid_mlx") { return .rapidMLX }
        // mlx-dspark (ARahim3/mlx-dspark) — OpenAI-compatible speculative-decoding server for MLX
        // (`mlx-dspark serve`, default :8080). Also checked before the generic MLX arm. The console
        // entry point is a shebang Python file, so macOS reports the interpreter and `/bin/mlx-dspark`
        // lives in argv (mirrors vLLM/exo). Every argv signal is bounded on BOTH sides — leading
        // `/bin/` / `-m `, trailing space-or-end — so an `mlx-dspark` checkout folder, a user's
        // --prefix-cache-dir path in an unrelated process's argv, or a sibling helper script
        // (`mlx-dspark-backup`) can't false-positive on the substring (mirrors the vLLM bound / #38).
        if base == "mlx-dspark"
            || a.contains("/bin/mlx-dspark ") || a.hasSuffix("/bin/mlx-dspark")
            || a.contains("-m mlx_dspark ") || a.hasSuffix("-m mlx_dspark") { return .mlxDSpark }
        if ["llama-server", "llama-cli", "llama-bench"].contains(base) { return .llamaCpp }
        if a.contains("mlx_lm.server") || a.contains("mlx_lm.generate") || a.contains("mlx_lm") { return .mlx }
        if base == "lms" || p.contains("LM Studio") || a.contains("LM Studio") { return .lmStudio }
        // vLLM — OpenAI-compatible server launched via the `vllm` console entry point
        // (/.../bin/vllm serve) or a Python module invocation (python -m vllm[.entrypoints]). The
        // `vllm` console script is a shebang Python file, so on macOS proc_pidpath reports the
        // interpreter (base "python*") and the script path lives in argv — `/bin/vllm` is the real
        // signal there, mirroring exo's `/bin/exo`. `base == "vllm"` is a defensive fallback (a
        // native build, or a proc table that reports the script). Every signal is bounded so a `vllm`
        // username or a same-named source folder can't false-positive on the bare substring (mirrors
        // the #38 jan/gpt4all bound and the exo arm's bounded-argv style).
        if base == "vllm" || a.contains("/bin/vllm") || a.contains("-m vllm") || a.contains("vllm.entrypoints") { return .vllm }
        // exo (exo-explore/exo) — OpenAI-compatible cluster inference server on :52415. Match the
        // installed console entry point (basename `exo`), the source module file, or a `-m exo.main`
        // invocation. Every signal is bounded by a path separator or a leading space so unrelated
        // names (hexo, Plexos, nexo) can't false-positive on the short "exo" substring.
        if base == "exo" || p.contains("/exo/main.py")
            || a.contains("/exo/main.py") || a.contains("/bin/exo") || a.contains(" exo.main") { return .exo }
        if base == "omlx" || base == "oMLX" || base == "omlx-server" || base == "oMLX-server" { return .omlx }

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
