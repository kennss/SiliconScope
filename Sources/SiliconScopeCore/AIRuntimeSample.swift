//
//  File:      AIRuntimeSample.swift
//  Created:   2026-06-14
//  Updated:   2026-06-25
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
}
