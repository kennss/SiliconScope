//
//  File:      SystemSnapshot.swift
//  Created:   2026-06-08
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  One unified reading of every SiliconScope metric, produced by SystemSampler
//             and consumed by the UI. Pure value type (Sendable).
//  Notes:     likelyAIEngine is a heuristic hint for the AI Workload view: LLMs hit
//             GPU/Metal + memory bandwidth (ANE idle); CoreML media features hit ANE.
//
import Foundation

public struct SystemSnapshot: Sendable {
    public var power = PowerSample()
    public var cpu = CPUSample()
    public var gpu = GPUSample()
    public var memory = MemorySample()
    public var bandwidth = BandwidthSample()
    public var thermal = ThermalSample()
    public var temperature = TemperatureSample()
    public var network = NetworkSample()
    public var disk = DiskSample()
    public var battery = BatteryInfo()
    public var processes: [ProcessRow] = []
    public var memoryBudget = MemoryBudget.empty
    public var aiRuntime = AIRuntimeSample()
    public var runtimeAPI = RuntimeAPISample()   // stamped by the monitor (opt-in poll)

    public init() {}

    /// Sudoless CPU-offload hint (est.): an active runtime burning CPU while the GPU is
    /// only moderately busy suggests weights are partly on CPU — the #1 "why is it slow".
    /// Anchored on the classifier's idle (0.30) / compute-bound (0.90) GPU thresholds.
    /// Not authoritative (the exact split needs feature ③); contextually nudges enabling it.
    public var aiCPUOffloadLikely: Bool {
        guard aiRuntime.isActive else { return false }
        return aiRuntime.totalCPUPercent > 100 && gpu.usage > 0.30 && gpu.usage < 0.90
    }

    /// Heuristic: which compute engine the current workload most likely uses.
    public var likelyAIEngine: String {
        if power.aneWatts > 1.0 { return "ANE (CoreML-style)" }
        if gpu.usage > 0.25 || power.gpuWatts > 3.0 || bandwidth.gpuGBs > 20 {
            return "GPU / Metal (LLM-style)"
        }
        return "idle"
    }

    public struct Warning: Sendable, Identifiable, Equatable {
        public enum Level: Sendable, Equatable { case warning, critical }
        public let level: Level
        public let message: String
        public var id: String { message }

        public init(level: Level, message: String) {
            self.level = level
            self.message = message
        }
    }

    /// Data-level alerts (thermal, memory, swap). UI may add context-dependent ones
    /// (e.g. bandwidth-bound) that need the observed peak.
    public var warnings: [Warning] {
        var result: [Warning] = []
        switch thermal.pressure {
        case .critical: result.append(.init(level: .critical, message: "Thermal throttling — critical"))
        case .serious:  result.append(.init(level: .warning, message: "Thermal pressure — serious"))
        default: break
        }
        switch memory.pressure {
        case .critical: result.append(.init(level: .critical, message: "Memory pressure: critical"))
        case .warning:  result.append(.init(level: .warning, message: "Memory pressure: elevated"))
        case .normal:   break
        }
        // Note: a predictive "swapping now" warning is rate-based and lives on the monitor
        // (memoryRisk → Dashboard banner). swapUsedBytes is cumulative/sticky, so it is not
        // turned into a warning here (it would false-positive long after pressure clears).
        return result
    }
}
