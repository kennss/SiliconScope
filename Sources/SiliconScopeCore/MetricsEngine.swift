//
//  File:      MetricsEngine.swift
//  Created:   2026-06-25
//  Updated:   2026-07-16
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The path-dependent derivation that turns a stream of SystemSnapshots into the
//             values the dashboard reads beyond the raw snapshot: rolling sparkline History,
//             slowly-decaying peaks (bandwidth/media/ANE/GPU-clock), memory-rate deltas, and the
//             computed throttle / ceiling / bottleneck / memory-risk verdicts. Extracted from
//             SiliconScopeMonitor so the SAME logic drives both the live monitor and session
//             replay — guaranteeing the replayed dashboard matches what was shown live.
//  Notes:     Pure (no UI, no syscalls). `ingest(_:dt:)` advances one frame; `dt` is the seconds
//             since the previous frame (wall-clock when live, the recording's frame delta when
//             replaying) — the rates are deterministic in `dt`. Decay/floor constants and
//             thresholds are copied verbatim from the previous inline monitor logic.
//
import Foundation

public final class MetricsEngine {
    /// Rolling time-series for sparklines (last ~60 samples per series).
    public struct History: Sendable {
        public var soc: [Double] = []
        public var pCPU: [Double] = []         // 0...1
        public var eCPU: [Double] = []         // 0...1
        public var gpu: [Double] = []          // 0...1
        public var gpuMem: [Double] = []       // 0...1 (GPU in-use memory / total unified memory)
        public var ane: [Double] = []          // Watts
        public var media: [Double] = []        // GB/s (Media Engine)
        public var bandwidth: [Double] = []    // GB/s
        public var dieTemp: [Double] = []      // Celsius
        public var memory: [Double] = []       // GB used
        public var memFraction: [Double] = []  // 0...1 (used / total) — plotted on a fixed 0...1 axis
        public var netDown: [Double] = []      // bytes/s
        public var netUp: [Double] = []        // bytes/s
        public var diskRead: [Double] = []     // bytes/s
        public var diskWrite: [Double] = []    // bytes/s

        public init() {}

        public mutating func push(_ s: SystemSnapshot) {
            roll(&soc, s.power.socWatts)
            roll(&pCPU, s.cpu.pUsage)
            roll(&eCPU, s.cpu.eUsage)
            roll(&gpu, s.gpu.usage)
            roll(&gpuMem, s.gpu.inUseMemoryFraction)
            roll(&ane, s.power.aneWatts)
            roll(&media, s.bandwidth.mediaGBs)
            roll(&bandwidth, s.bandwidth.totalGBs)
            roll(&dieTemp, s.temperature.cpuCelsius)
            roll(&memory, s.memory.usedGB)
            roll(&memFraction, s.memory.usedFraction)
            roll(&netDown, s.network.downloadBytesPerSec)
            roll(&netUp, s.network.uploadBytesPerSec)
            roll(&diskRead, s.disk.readBytesPerSec)
            roll(&diskWrite, s.disk.writeBytesPerSec)
        }
        private func roll(_ series: inout [Double], _ value: Double) {
            series.append(value)
            if series.count > 60 { series.removeFirst(series.count - 60) }
        }
    }

    // Latest ingested snapshot — the basis for the snapshot-dependent computed verdicts.
    public private(set) var latest = SystemSnapshot()
    public private(set) var history = History()

    // Chip-agnostic bar scaling: track observed peaks instead of hardcoding per-chip maxima.
    public private(set) var bandwidthPeakGBs: Double = 80
    public private(set) var mediaPeakGBs: Double = 2
    public private(set) var anePeakWatts: Double = 2
    public private(set) var gpuClockPeakMHz: Double = 0
    private static let peakDecay = 0.999
    private static let gpuClockPeakDecay = 0.999

    // Memory-pressure precursor: rate deltas of the lifetime VM counters (pages/sec).
    public private(set) var memoryPageInRate: Double = 0
    public private(set) var memoryPageOutRate: Double = 0
    public private(set) var memorySwapInRate: Double = 0     // recovery reads (normal)
    public private(set) var memorySwapOutRate: Double = 0    // swapouts/sec — eviction under pressure
    public private(set) var memoryCompressionRate: Double = 0
    private static let compressionRatePagesPerSec = 200.0
    private struct MemCounters { let pageins, pageouts, swapins, swapouts, compressions: UInt64 }
    private var previousMem: MemCounters?

    private let topology: CPUTopology?

    public init(topology: CPUTopology?) { self.topology = topology }

    /// Advances the engine by one frame. `dt` = seconds since the previous frame.
    public func ingest(_ s: SystemSnapshot, dt: TimeInterval) {
        latest = s
        bandwidthPeakGBs = max(s.bandwidth.totalGBs, max(40, bandwidthPeakGBs * Self.peakDecay))
        mediaPeakGBs = max(s.bandwidth.mediaGBs, max(1, mediaPeakGBs * Self.peakDecay))
        anePeakWatts = max(s.power.aneWatts, max(1, anePeakWatts * Self.peakDecay))
        gpuClockPeakMHz = max(s.gpu.freqMHz, gpuClockPeakMHz * Self.gpuClockPeakDecay)
        updateMemoryRates(s.memory, dt: dt)
        history.push(s)
    }

    /// Clears rate state so the next frame emits no spurious delta (e.g. after a (re)start).
    public func reset() {
        previousMem = nil
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }

    // MARK: - Computed verdicts (snapshot + path-dependent state)
    //
    // The instance properties delegate to pure static functions so the replay path can compute the
    // EXACT same verdicts from a recorded frame's snapshot + precomputed scalars + rebuilt history.

    public var gpuThrottling: Bool { Self.gpuThrottling(latest: latest, gpuClockPeakMHz: gpuClockPeakMHz) }
    public var gpuClockDropFraction: Double { Self.gpuClockDropFraction(latest: latest, gpuClockPeakMHz: gpuClockPeakMHz) }
    public var cpuThrottling: Bool { Self.cpuThrottling(latest: latest, topology: topology) }
    public var cpuClockDropFraction: Double { Self.cpuClockDropFraction(latest: latest, topology: topology) }
    public var bandwidthCeilingGBs: Double { Self.bandwidthCeiling(topology: topology, bandwidthPeakGBs: bandwidthPeakGBs) }
    public var bottleneck: Bottleneck {
        Self.bottleneck(latest: latest, history: history, bandwidthPeakGBs: bandwidthPeakGBs, throttling: gpuThrottling)
    }
    public var memoryRisk: MemoryBudget.Risk {
        Self.memoryRisk(latest: latest, swapOutRate: memorySwapOutRate, compressionRate: memoryCompressionRate)
    }

    /// True when the GPU clock is held well below its rolling peak while the GPU is active and
    /// thermal pressure has risen above nominal — i.e. thermal throttling.
    public static func gpuThrottling(latest: SystemSnapshot, gpuClockPeakMHz: Double) -> Bool {
        guard gpuClockPeakMHz > 0 else { return false }
        return latest.gpu.usage > 0.3
            && latest.thermal.pressure != .nominal
            && latest.gpu.freqMHz < 0.85 * gpuClockPeakMHz
    }

    /// How far the current GPU clock sits below its rolling peak (0...1; 0 when at/above).
    public static func gpuClockDropFraction(latest: SystemSnapshot, gpuClockPeakMHz: Double) -> Double {
        guard gpuClockPeakMHz > 0, latest.gpu.freqMHz < gpuClockPeakMHz else { return 0 }
        return 1 - latest.gpu.freqMHz / gpuClockPeakMHz
    }

    /// True when the P-cluster clock is held well below the chip's top DVFS step while the P-cores are
    /// busy and thermal pressure has risen above nominal — i.e. CPU thermal throttling. Symmetric to
    /// gpuThrottling, but ceilinged on the per-chip DVFS max (topology.pFreqsMHz) rather than an
    /// observed peak, so the verdict is identical on live and replay (topology travels in the recording).
    public static func cpuThrottling(latest: SystemSnapshot, topology: CPUTopology?) -> Bool {
        guard let pMax = topology?.pFreqsMHz.max(), pMax > 0 else { return false }
        return latest.cpu.pUsage > 0.3
            && latest.thermal.pressure != .nominal
            && latest.cpu.pFreqMHz < 0.85 * pMax
    }

    /// How far the current P-cluster clock sits below the chip's top DVFS step (0...1; 0 when at/above).
    public static func cpuClockDropFraction(latest: SystemSnapshot, topology: CPUTopology?) -> Double {
        guard let pMax = topology?.pFreqsMHz.max(), pMax > 0, latest.cpu.pFreqMHz < pMax else { return 0 }
        return 1 - latest.cpu.pFreqMHz / pMax
    }

    /// Unified-memory bandwidth ceiling (GB/s): the per-chip spec value, raised to the observed
    /// peak if traffic ever exceeds it (so it never under-reports and works on unlisted chips).
    public static func bandwidthCeiling(topology: CPUTopology?, bandwidthPeakGBs: Double) -> Double {
        let spec = topology.map { Bottleneck.bandwidthCeilingGBs(chipName: $0.chipName, pCoreCount: $0.pCoreCount) } ?? 0
        return max(spec, bandwidthPeakGBs)
    }

    /// The single dominant AI-workload bottleneck. Classified on a short rolling average of GPU%
    /// and bandwidth so the verdict doesn't flicker sample-to-sample.
    public static func bottleneck(latest: SystemSnapshot, history: History,
                                  bandwidthPeakGBs: Double, throttling: Bool) -> Bottleneck {
        Bottleneck.classify(memoryCritical: latest.memory.pressure == .critical,
                            gpuUsage: tailAverage(history.gpu, count: 3, fallback: latest.gpu.usage),
                            bandwidthGBs: tailAverage(history.bandwidth, count: 3, fallback: latest.bandwidth.totalGBs),
                            achievableGBs: bandwidthPeakGBs,
                            throttling: throttling)
    }

    /// Refined memory risk: the static budget baseline plus swap/compression rates.
    public static func memoryRisk(latest: SystemSnapshot, swapOutRate: Double,
                                  compressionRate: Double) -> MemoryBudget.Risk {
        let base = latest.memoryBudget.risk
        if base == .swapping || swapOutRate > 0 { return .swapping }
        if compressionRate > compressionRatePagesPerSec && latest.memoryBudget.headroomNowBytes < (1 << 30) {
            return .tight
        }
        return base
    }

    private static func tailAverage(_ values: [Double], count: Int, fallback: Double) -> Double {
        let tail = values.suffix(count)
        return tail.isEmpty ? fallback : tail.reduce(0, +) / Double(tail.count)
    }

    private func updateMemoryRates(_ m: MemorySample, dt: TimeInterval) {
        let cur = MemCounters(pageins: m.pageins, pageouts: m.pageouts, swapins: m.swapins,
                              swapouts: m.swapouts, compressions: m.compressions)
        defer { previousMem = cur }
        guard let prev = previousMem, dt > 0 else { resetRatesOnly(); return }
        func delta(_ now: UInt64, _ was: UInt64) -> Double { now >= was ? Double(now - was) : 0 }
        memoryPageInRate = delta(cur.pageins, prev.pageins) / dt
        memoryPageOutRate = delta(cur.pageouts, prev.pageouts) / dt
        memorySwapInRate = delta(cur.swapins, prev.swapins) / dt
        // Only swapouts (eviction under pressure) signal a problem; swapins are recovery reads
        // of pages swapped earlier and must NOT trip the "swapping" warning.
        memorySwapOutRate = delta(cur.swapouts, prev.swapouts) / dt
        memoryCompressionRate = delta(cur.compressions, prev.compressions) / dt
    }

    /// Zeros the rates without touching previousMem (the caller's defer sets it).
    private func resetRatesOnly() {
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }
}
