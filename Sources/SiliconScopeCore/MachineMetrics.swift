//
//  File:      MachineMetrics.swift
//  Created:   2026-07-21
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The source-agnostic fleet metric schema — the boundary the Mac aggregator consumes
//             for every remote machine, regardless of how the data arrives. Mirrors the Go Linux
//             agent's JSON (agent/main.go) so its output decodes directly, and carries Apple-Silicon
//             extras (E/P split, ANE/Media, per-requestor bandwidth, power breakdown, fans) that a
//             Mac agent fills in. Keeping this UI-independent (Core) is what lets one view render
//             both a Linux GPU box and a headless Mac.
//  Notes:     JSON keys are camelCase matching the property names, so no CodingKeys are needed.
//             Apple-only fields are Optional so Linux JSON (which omits them) still decodes — the
//             UI shows a slot only when its value is present. Byte fields are absolute bytes; `ts`
//             is unix ms. `kind` is "linux" | "mac". All fleet types are `Fleet*`-prefixed to avoid
//             colliding with the local live-monitor snapshot types.
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
    public let apple: FleetApple?      // Apple-Silicon extras; nil on Linux

    public init(machineId: String, hostname: String, os: String, kind: String, agentVersion: String,
                ts: Int64, cpu: FleetCPU, memory: FleetMemory, gpus: [FleetGPU],
                llm: FleetLLM? = nil, apple: FleetApple? = nil) {
        self.machineId = machineId; self.hostname = hostname; self.os = os; self.kind = kind
        self.agentVersion = agentVersion; self.ts = ts; self.cpu = cpu; self.memory = memory
        self.gpus = gpus; self.llm = llm; self.apple = apple
    }
}

public struct FleetCPU: Codable, Sendable, Equatable {
    public let cores: Int
    public let usagePercent: Double
    public let loadAvg1: Double
    // Apple E/P cluster split (nil on Linux, which reports one blended usagePercent).
    public let eUsagePercent: Double?
    public let pUsagePercent: Double?
    public let eFreqMHz: Double?
    public let pFreqMHz: Double?
    public let eCores: Int?          // Apple E/P core counts (nil on Linux)
    public let pCores: Int?

    public init(cores: Int, usagePercent: Double, loadAvg1: Double,
                eUsagePercent: Double? = nil, pUsagePercent: Double? = nil,
                eFreqMHz: Double? = nil, pFreqMHz: Double? = nil,
                eCores: Int? = nil, pCores: Int? = nil) {
        self.cores = cores; self.usagePercent = usagePercent; self.loadAvg1 = loadAvg1
        self.eUsagePercent = eUsagePercent; self.pUsagePercent = pUsagePercent
        self.eFreqMHz = eFreqMHz; self.pFreqMHz = pFreqMHz
        self.eCores = eCores; self.pCores = pCores
    }
}

public struct FleetMemory: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
    }
}

public struct FleetGPUProc: Codable, Sendable, Equatable {
    public let pid: Int
    public let name: String
    public let vramBytes: Int64

    public init(pid: Int, name: String, vramBytes: Int64) {
        self.pid = pid; self.name = name; self.vramBytes = vramBytes
    }
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
    public let freqMHz: Double?         // GPU clock; nil when the agent doesn't report it

    public init(index: Int, name: String, driver: String, vramTotalBytes: Int64, vramUsedBytes: Int64,
                utilizationPercent: Double, temperatureC: Double, powerDrawW: Double, powerLimitW: Double,
                processes: [FleetGPUProc], freqMHz: Double? = nil) {
        self.index = index; self.name = name; self.driver = driver
        self.vramTotalBytes = vramTotalBytes; self.vramUsedBytes = vramUsedBytes
        self.utilizationPercent = utilizationPercent; self.temperatureC = temperatureC
        self.powerDrawW = powerDrawW; self.powerLimitW = powerLimitW
        self.processes = processes; self.freqMHz = freqMHz
    }

    /// VRAM fraction used (0…1), for a bar.
    public var vramFraction: Double { vramTotalBytes > 0 ? Double(vramUsedBytes) / Double(vramTotalBytes) : 0 }
}

public struct FleetLLMModel: Codable, Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64

    public init(name: String, sizeBytes: Int64) { self.name = name; self.sizeBytes = sizeBytes }
}

public struct FleetOllama: Codable, Sendable, Equatable {
    public let running: Bool
    public let models: [FleetLLMModel]
    public let loaded: [FleetLLMModel]

    public init(running: Bool, models: [FleetLLMModel], loaded: [FleetLLMModel]) {
        self.running = running; self.models = models; self.loaded = loaded
    }
}

public struct FleetLLM: Codable, Sendable, Equatable {
    public let ollama: FleetOllama?
    public init(ollama: FleetOllama?) { self.ollama = ollama }
}

// MARK: - Apple-Silicon extras (Mac agent)

/// Metrics unique to Apple Silicon that have no place in the Linux/NVIDIA shape: the Neural Engine
/// and Media engine, per-requestor memory bandwidth, a full power breakdown, and fan speeds. All
/// present only when `kind == "mac"`.
public struct FleetApple: Codable, Sendable, Equatable {
    public let chip: String            // e.g. "Apple M1 Max"
    public let aneWatts: Double        // Neural Engine power (estimate — no util API exists)
    public let anePeakWatts: Double    // for bar scaling
    public let mediaGBs: Double        // Media engine throughput (GB/s)
    public let mediaPeakGBs: Double
    public let socWatts: Double        // whole-SoC power (sensor or derived sum)
    public let power: FleetPower
    public let bandwidth: FleetBandwidth
    public let fanRPMs: [Double]       // empty on fanless Macs (MacBook Air)

    public init(chip: String, aneWatts: Double, anePeakWatts: Double, mediaGBs: Double,
                mediaPeakGBs: Double, socWatts: Double, power: FleetPower,
                bandwidth: FleetBandwidth, fanRPMs: [Double]) {
        self.chip = chip; self.aneWatts = aneWatts; self.anePeakWatts = anePeakWatts
        self.mediaGBs = mediaGBs; self.mediaPeakGBs = mediaPeakGBs; self.socWatts = socWatts
        self.power = power; self.bandwidth = bandwidth; self.fanRPMs = fanRPMs
    }

    public var hasFans: Bool { !fanRPMs.isEmpty }
}

public struct FleetPower: Codable, Sendable, Equatable {
    public let cpuWatts: Double
    public let eCpuWatts: Double
    public let pCpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double
    public let dramWatts: Double

    public init(cpuWatts: Double, eCpuWatts: Double, pCpuWatts: Double,
                gpuWatts: Double, aneWatts: Double, dramWatts: Double) {
        self.cpuWatts = cpuWatts; self.eCpuWatts = eCpuWatts; self.pCpuWatts = pCpuWatts
        self.gpuWatts = gpuWatts; self.aneWatts = aneWatts; self.dramWatts = dramWatts
    }
}

public struct FleetBandwidth: Codable, Sendable, Equatable {
    public let cpuGBs: Double
    public let gpuGBs: Double
    public let mediaGBs: Double
    public let otherGBs: Double
    public let totalGBs: Double
    public let isEstimated: Bool

    public init(cpuGBs: Double, gpuGBs: Double, mediaGBs: Double, otherGBs: Double,
                totalGBs: Double, isEstimated: Bool) {
        self.cpuGBs = cpuGBs; self.gpuGBs = gpuGBs; self.mediaGBs = mediaGBs
        self.otherGBs = otherGBs; self.totalGBs = totalGBs; self.isEstimated = isEstimated
    }
}
