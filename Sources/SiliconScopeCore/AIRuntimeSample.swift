//
//  File:      AIRuntimeSample.swift
//  Created:   2026-06-14
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Per-snapshot result of AI-runtime detection: the matched processes plus
//             grouped roll-ups (RAM / CPU% per kind, primary kind, embedded port).
//  Notes:     CPU%/RAM come straight from the matched ProcessRows, so they agree with the
//             Processes table by construction. No per-process GPU (sudoless-impossible —
//             never claimed). primaryKind ranks by grouped RSS (bundle identity already
//             collapsed e.g. the Ollama parent + runner into one .ollama group).
//
import Foundation

public struct AIRuntimeProcess: Sendable, Equatable, Identifiable, Codable {
    public let pid: Int32
    public let kind: AIRuntimeKind
    public let displayName: String
    public let cpuPercent: Double      // summed across cores (ProcessRow convention)
    public let memoryBytes: UInt64     // RSS
    public let embeddedPort: Int?      // parsed from argv (e.g. Ollama runner --port)
    public var id: Int32 { pid }

    public init(pid: Int32, kind: AIRuntimeKind, displayName: String,
                cpuPercent: Double, memoryBytes: UInt64, embeddedPort: Int?) {
        self.pid = pid
        self.kind = kind
        self.displayName = displayName
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.embeddedPort = embeddedPort
    }
}

public struct AIRuntimeSample: Sendable, Equatable, Codable {
    public var processes: [AIRuntimeProcess] = []

    public init() {}

    public var isActive: Bool { !processes.isEmpty }

    /// Headline kind = largest grouped RSS (RSS only ranks *within/across* kinds; bundle
    /// identity already collapsed multi-process runtimes into one kind).
    public var primaryKind: AIRuntimeKind? {
        Dictionary(grouping: processes, by: \.kind)
            .max { lhs, rhs in
                lhs.value.reduce(0) { $0 + $1.memoryBytes } < rhs.value.reduce(0) { $0 + $1.memoryBytes }
            }?.key
    }

    public func processes(of kind: AIRuntimeKind) -> [AIRuntimeProcess] {
        processes.filter { $0.kind == kind }
    }

    public func memoryBytes(of kind: AIRuntimeKind) -> UInt64 {
        processes(of: kind).reduce(0) { $0 + $1.memoryBytes }
    }

    public func cpuPercent(of kind: AIRuntimeKind) -> Double {
        processes(of: kind).reduce(0) { $0 + $1.cpuPercent }
    }

    public var totalMemoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    public var totalCPUPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }

    /// RSS of the headline runtime (what feature ② treats as the unloadable resident model).
    public var primaryMemoryBytes: UInt64 {
        guard let kind = primaryKind else { return 0 }
        return memoryBytes(of: kind)
    }

    public var ollamaEmbeddedPort: Int? {
        processes.first { $0.kind == .ollama && $0.embeddedPort != nil }?.embeddedPort
    }

    /// The `--port` a running process of `kind` was started with, if any was seen in its argv.
    public func observedPort(of kind: AIRuntimeKind) -> Int? {
        processes.first { $0.kind == kind && $0.embeddedPort != nil }?.embeddedPort
    }

    /// Where `kind`'s local API answers — the one answer to that question, shared by the model
    /// probe and the benchmark (and the CLI).
    ///
    /// ⚠️ This used to be three switch statements in three files. They drifted: the benchmark
    /// once read an Ollama-kind port for a llama.cpp runtime and knocked on :8080 while the probe
    /// asked the right port (#52/#53). Every runtime added since would have needed three edits
    /// that had to agree.
    ///
    /// Order of trust: what the process was SEEN serving on (its argv `--port`), then the user's
    /// setting for the three runtimes that have one, then the runtime's documented default.
    /// llama.cpp is the exception: with no observed server there is nothing to ask, and nil says so
    /// — a conventional port is exactly the neighbourhood polling #53 removed.
    public func apiPort(for kind: AIRuntimeKind, configured: RuntimePorts = RuntimePorts()) -> Int? {
        switch kind {
        case .ollama:    return configured.ollama
        case .lmStudio:  return configured.lmStudio
        case .omlx:      return configured.omlx
        case .llamaCpp:  return llamaCppPort
        case .rapidMLX:  return 8000
        case .exo:       return 52415
        case .mlxDSpark: return observedPort(of: .mlxDSpark) ?? 8080   // `mlx-dspark serve` default
        // Only a process seen to be the server has a port (`AIRuntimeKind.servingPort`): their
        // CLIs serve nothing, and 8000 is shared with oMLX and Rapid-MLX.
        case .mtplx:     return observedPort(of: .mtplx)
        case .ds4:       return observedPort(of: .ds4)
        case .mlx, .jan, .gpt4all, .vllm, .spectalo, .spectaling, .other: return nil
        }
    }

    /// Where a llama.cpp server that is ACTUALLY RUNNING listens: its own `--port` when it was
    /// given one (Ollama's runner child always is), otherwise llama-server's documented default.
    ///
    /// ⚠️ `nil` means "no llama.cpp process exists", and callers must read it as *there is nothing
    /// to ask* — never as a cue to try a conventional port anyway. Guessing is what made
    /// SiliconScope GET 127.0.0.1:8080/metrics and :8081/metrics every 3 s on every Mac, whether
    /// or not any AI runtime was installed, so whoever else happened to own 8080 kept receiving
    /// our traffic (#53). Observe the process, don't poll the neighbourhood.
    /// Whether an LM Studio process is running right now.
    ///
    /// ⚠️ Read this before touching the `lms` CLI, never after: `lms log stream` STARTS LM Studio
    /// in service mode when it is not already up, so asking it for a rate is enough to launch the
    /// app (#60). Observation first, attachment second.
    public var isLMStudioRunning: Bool { !processes(of: .lmStudio).isEmpty }

    public var llamaCppPort: Int? {
        let servers = processes(of: .llamaCpp)
        guard !servers.isEmpty else { return nil }
        return servers.first { $0.embeddedPort != nil }?.embeddedPort ?? 8080
    }
}

/// The API ports a user can change in Settings. Everything else is observed or documented.
public struct RuntimePorts: Sendable, Equatable {
    public var ollama: Int
    public var lmStudio: Int
    public var omlx: Int

    public init(ollama: Int = 11434, lmStudio: Int = 1234, omlx: Int = 8000) {
        self.ollama = ollama; self.lmStudio = lmStudio; self.omlx = omlx
    }
}

