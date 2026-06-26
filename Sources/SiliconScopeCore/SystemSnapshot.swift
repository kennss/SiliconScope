//
//  File:      SystemSnapshot.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  One unified reading of every SiliconScope metric, produced by SystemSampler
//             and consumed by the UI. Pure value type (Sendable).
//  Notes:     likelyAIEngine is a heuristic hint for the AI Workload view: LLMs hit
//             GPU/Metal + memory bandwidth (ANE idle); CoreML media features hit ANE.
//
import Foundation

public struct SystemSnapshot: Sendable, Codable {
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
    public var peripherals: [PeripheralBattery] = []   // connected accessories with a readable battery
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

    /// Honest workload attribution. GPU activity alone is NOT AI — it could be graphics,
    /// gaming, or video. We only assert "LLM" with evidence (a runtime serving a loaded
    /// model, or a multi-GB resident model in a detected runtime); ANE power implies ML;
    /// Media-engine traffic implies video. Otherwise we say the type is unknown.
    public var likelyAIEngine: String {
        if runtimeAPI.isReachable, !runtimeAPI.loadedModels.isEmpty { return "LLM (GPU/Metal)" }
        if aiRuntime.primaryMemoryBytes > (2 << 30) { return "LLM (likely)" }
        if power.aneWatts > 1.0 { return "ANE (CoreML)" }
        let gpuBusy = gpu.usage > 0.25 || power.gpuWatts > 3.0 || bandwidth.gpuGBs > 20
        guard gpuBusy else { return "idle" }
        if bandwidth.mediaGBs > 0.5 { return "GPU active — incl. video" }
        return "GPU active — type unknown"
    }

    /// True when a detected runtime actually holds a model — an API-reported loaded model,
    /// or a multi-GB resident model. A bare daemon (e.g. Ollama idling at ~0.1 GB with no
    /// model) is NOT active, so we never credit it for GPU work done by something else.
    public var aiModelActive: Bool {
        (runtimeAPI.isReachable && !runtimeAPI.loadedModels.isEmpty)
            || aiRuntime.primaryMemoryBytes > (1 << 30)
    }

    /// GPU is doing genuine compute (not just light UI). Used to recognize an unmanaged /
    /// in-app AI workload (e.g. an MLX-Swift app like WhisPlay) when no managed runtime
    /// holds a model — we say so honestly instead of crediting an idle daemon.
    public var gpuComputeBusy: Bool { gpu.usage > 0.40 || power.gpuWatts > 4.0 }

    /// Honest one-line AI-runtime status for compact UI (menu bar). A detected runtime is
    /// "active" only when it holds a model; a bare daemon reads "(idle)"; an unattributed
    /// GPU compute load reads "in-app / unmanaged".
    public var aiRuntimeLabel: String {
        if let kind = aiRuntime.primaryKind {
            if runtimeAPI.isReachable, let m = runtimeAPI.primaryModel { return "\(kind.displayName) · \(m.name)" }
            if aiRuntime.primaryMemoryBytes > (1 << 30) { return kind.displayName }
            return gpuComputeBusy ? "\(kind.displayName) idle · GPU: other app" : "\(kind.displayName) (idle)"
        }
        return gpuComputeBusy ? "in-app / unmanaged" : "none"
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
