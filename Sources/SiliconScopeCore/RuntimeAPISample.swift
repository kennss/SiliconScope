//
//  File:      RuntimeAPISample.swift
//  Created:   2026-06-14
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Result of an OPT-IN poll of a local AI runtime's HTTP API (Ollama,
//             llama.cpp server, LM Studio). Carries the loaded model(s), the authoritative
//             GPU/CPU split (Ollama size_vram/size), and tokens/sec when the runtime
//             exposes it. Mmap-independent — fixes the RSS under-count for resident models.
//  Notes:     tokensPerSec is nil unless the runtime reports it (never fabricated). The
//             monitor owns the live value on its own cadence and stamps the latest into
//             SystemSnapshot; a staleness guard downgrades a wedged poll to .unreachable.
//
import Foundation

public struct RuntimeModelInfo: Sendable, Equatable, Identifiable {
    public let name: String
    public let sizeBytes: UInt64        // total model size (Ollama); 0 if the API omits it
    public let sizeVRAMBytes: UInt64    // resident on GPU (Ollama size_vram); 0 if unknown
    public let parameterSize: String?   // "12.2B"
    public let quantization: String?    // "Q4_K_M"
    public let contextLength: Int?      // feeds feature ②'s KV math
    public var id: String { name }

    public init(name: String, sizeBytes: UInt64, sizeVRAMBytes: UInt64,
                parameterSize: String?, quantization: String?, contextLength: Int?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.sizeVRAMBytes = sizeVRAMBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.contextLength = contextLength
    }

    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
    public var gpuFraction: Double { sizeBytes > 0 ? Double(sizeVRAMBytes) / Double(sizeBytes) : 0 }

    /// Authoritative processor split, or nil when the API doesn't report sizes (LM Studio).
    public var processorLabel: String? {
        guard sizeBytes > 0 else { return nil }
        let gpu = Int((gpuFraction * 100).rounded())
        if gpu >= 99 { return "100% GPU" }
        if gpu <= 1  { return "100% CPU" }
        return "\(100 - gpu)%/\(gpu)% CPU/GPU"
    }
}

public struct RuntimeAPISample: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable { case ollama, llamaCpp, lmStudio }
    public enum Status: String, Sendable, Equatable {
        case disabled            // feature off
        case unreachable         // no runtime / port closed / decode failure / stale (C4)
        case runningNoServer     // ① detected a runtime but its API/server isn't answering
        case apiNotApplicable    // bare CLI llama.cpp (no HTTP server)
        case ok
    }

    public var status: Status = .disabled
    public var source: Source?
    public var loadedModels: [RuntimeModelInfo] = []
    public var tokensPerSec: Double?       // nil unless the runtime reports it
    public var lastUpdated: Date?

    public init() {}

    public var isReachable: Bool { status == .ok }
    public var primaryModel: RuntimeModelInfo? { loadedModels.first }
}
