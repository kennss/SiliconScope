//
//  File:      MachineMetrics.swift
//  Created:   2026-07-21
//  Updated:   2026-07-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The source-agnostic fleet metric schema — the boundary the Mac aggregator consumes
//             for every remote machine, regardless of how the data arrives (SSH-pull, agent push).
//             Mirrors the Go Linux agent's JSON exactly (agent/main.go) so its output decodes
//             directly; a headless-Mac agent will emit the same shape (Apple GPU/ANE in `gpus`,
//             E/P split added to `cpu`). Keeping this UI-independent (Core) is what lets both the
//             interim SSH-pull source and a future encrypted agent-push transport feed one view.
//  Notes:     JSON keys are camelCase and match the property names, so no CodingKeys are needed.
//             Byte fields are absolute bytes; `ts` is unix milliseconds; VRAM/mem come pre-scaled
//             from the agent. `kind` is "linux" | "mac". All fleet types are `Fleet*`-prefixed to
//             avoid colliding with the local live-monitor snapshot types.
//
import Foundation

public struct MachineMetrics: Codable, Sendable, Identifiable, Equatable {
    public var id: String { machineId }
    public let machineId: String
    public let hostname: String
    public let os: String
    public let kind: String            // "linux" | "mac"
    public let agentVersion: String
    public let ts: Int64               // unix ms
    public let cpu: FleetCPU
    public let memory: FleetMemory
    public let gpus: [FleetGPU]
    public let llm: FleetLLM?
}

public struct FleetCPU: Codable, Sendable, Equatable {
    public let cores: Int
    public let usagePercent: Double
    public let loadAvg1: Double
}

public struct FleetMemory: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
}

public struct FleetGPUProc: Codable, Sendable, Equatable {
    public let pid: Int
    public let name: String
    public let vramBytes: Int64
}

public struct FleetGPU: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let driver: String
    public let vramTotalBytes: Int64
    public let vramUsedBytes: Int64
    public let utilizationPercent: Double
    public let temperatureC: Double
    public let powerDrawW: Double
    public let powerLimitW: Double
    public let processes: [FleetGPUProc]

    /// VRAM fraction used (0…1), for a bar.
    public var vramFraction: Double { vramTotalBytes > 0 ? Double(vramUsedBytes) / Double(vramTotalBytes) : 0 }
}

public struct FleetLLMModel: Codable, Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
}

public struct FleetOllama: Codable, Sendable, Equatable {
    public let running: Bool
    public let models: [FleetLLMModel]
    public let loaded: [FleetLLMModel]
}

public struct FleetLLM: Codable, Sendable, Equatable {
    public let ollama: FleetOllama?
}
