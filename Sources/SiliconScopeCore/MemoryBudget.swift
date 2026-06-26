//
//  File:      MemoryBudget.swift
//  Created:   2026-06-14
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Predictive unified-memory budget for local-AI users. Pure derivation from
//             a MemorySample (no syscalls): two honest "what fits" figures and a static
//             risk baseline. The monitor refines risk with rate deltas (see
//             SiliconScopeMonitor). All sizing is approximate (ANE-est posture).
//  Notes:     headroomNow = fits alongside everything resident (conservative — `used`
//             includes evictable cache). loadable = headroomNow + the active runtime's
//             RSS (what fits if you unload the current model; > headroom only once an AI
//             runtime is detected). Model sizing: weights ≈ params × bytesPerParam, minus
//             a coarse KV(context) + runtime overhead. Everything is a "~" estimate.
//
import Foundation

/// One quantization's "largest model that fits a byte budget" estimate.
public struct ModelFit: Sendable, Equatable, Identifiable, Codable {
    public let quant: String          // "Q4_K_M" / "Q8_0" / "F16"
    public let bytesPerParam: Double
    public let maxParamsBillions: Double
    public var id: String { quant }

    public init(quant: String, bytesPerParam: Double, maxParamsBillions: Double) {
        self.quant = quant
        self.bytesPerParam = bytesPerParam
        self.maxParamsBillions = maxParamsBillions
    }

    public var label: String {
        maxParamsBillions <= 0 ? "—" : String(format: "~%.0fB (%@)", maxParamsBillions, quant)
    }
}

public struct MemoryBudget: Sendable, Equatable, Codable {
    public enum Risk: String, Sendable, Equatable, Codable { case ok, tight, swapping }

    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let wiredBytes: UInt64
    public let swapUsedBytes: UInt64
    public let reservedBytes: UInt64        // OS/UI/app headroom kept back
    public let headroomNowBytes: UInt64     // fits alongside all resident memory
    public let loadableBytes: UInt64        // fits after unloading the current model
    public let risk: Risk                   // static baseline; monitor refines with rates
    public let contextTokens: Int           // assumption used for KV sizing

    public init(totalBytes: UInt64, usedBytes: UInt64, wiredBytes: UInt64,
                swapUsedBytes: UInt64, reservedBytes: UInt64, headroomNowBytes: UInt64,
                loadableBytes: UInt64, risk: Risk, contextTokens: Int) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.swapUsedBytes = swapUsedBytes
        self.reservedBytes = reservedBytes
        self.headroomNowBytes = headroomNowBytes
        self.loadableBytes = loadableBytes
        self.risk = risk
        self.contextTokens = contextTokens
    }

    private static let gb = 1024.0 * 1024.0 * 1024.0
    public var headroomNowGB: Double { Double(headroomNowBytes) / Self.gb }
    public var loadableGB: Double { Double(loadableBytes) / Self.gb }

    public static let empty = MemoryBudget(
        totalBytes: 0, usedBytes: 0, wiredBytes: 0, swapUsedBytes: 0, reservedBytes: 0,
        headroomNowBytes: 0, loadableBytes: 0, risk: .ok, contextTokens: 0
    )

    /// bytes/param for common GGUF quantizations.
    public static let quants: [(quant: String, bytesPerParam: Double)] = [
        ("Q4_K_M", 0.56), ("Q8_0", 1.06), ("F16", 2.0)
    ]

    /// Largest model (per quant) that fits `budgetBytes`, after a coarse KV(context) +
    /// runtime overhead. All values are rough "~" estimates.
    public func fits(_ budgetBytes: UInt64) -> [ModelFit] {
        let runtimeOverhead = 1.0 * Self.gb
        // Coarse KV-cache estimate: ~256 MB per 1024 context tokens (model-agnostic).
        let kvBytes = Double(contextTokens) / 1024.0 * 256.0 * 1024 * 1024
        let usable = max(0, Double(budgetBytes) - kvBytes - runtimeOverhead)
        return Self.quants.map { q in
            ModelFit(quant: q.quant, bytesPerParam: q.bytesPerParam,
                     maxParamsBillions: usable > 0 ? usable / q.bytesPerParam / 1e9 : 0)
        }
    }

    public var fitsNow: [ModelFit] { fits(headroomNowBytes) }
    public var fitsLoadable: [ModelFit] { fits(loadableBytes) }

    /// Derives the budget from a memory sample. `activeRuntimeRSS` (from feature ①) lifts
    /// `loadable` above `headroomNow`; defaults to 0 until runtime detection is wired.
    public static func estimate(memory: MemorySample,
                                activeRuntimeRSS: UInt64 = 0,
                                contextTokens: Int = 8192,
                                reserveFraction: Double = 0.10,
                                reserveFloorBytes: UInt64 = 3 << 30) -> MemoryBudget {
        let total = memory.totalBytes
        guard total > 0 else { return .empty }
        let used = memory.usedBytes
        let reserved = max(reserveFloorBytes, UInt64(Double(total) * reserveFraction))
        let headroom = total > used + reserved ? total - used - reserved : 0
        let loadable = headroom + activeRuntimeRSS

        // Static baseline only (one sample). usedFraction is deliberately NOT used (macOS
        // keeps it high via evictable cache), and swapUsedBytes is NOT used either — it is
        // cumulative on-disk swap that persists long after pressure clears (sticky, would
        // false-positive with plenty of headroom). "Actually swapping now" is a rate signal
        // the monitor adds (memoryRisk). Static swapping = critical OS pressure only.
        let risk: Risk
        if memory.pressure == .critical {
            risk = .swapping
        } else if headroom == 0 {
            risk = .tight
        } else {
            risk = .ok
        }

        return MemoryBudget(
            totalBytes: total, usedBytes: used, wiredBytes: memory.wiredBytes,
            swapUsedBytes: memory.swapUsedBytes, reservedBytes: reserved,
            headroomNowBytes: headroom, loadableBytes: loadable,
            risk: risk, contextTokens: contextTokens
        )
    }
}
