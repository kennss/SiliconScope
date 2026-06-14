//
//  File:      SiliconScopeMonitor.swift
//  Created:   2026-06-08
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Observable view-model that drives the UI. Polls SystemSampler on a
//             background task ~once per second and publishes the latest snapshot plus
//             a short SoC-power history for sparklines.
//  Notes:     Sampling runs via Task.detached (off main); SystemSampler is
//             @unchecked Sendable and only touched there. UI reads snapshot on main.
//             gpuClockPeakMHz is a slowly-decaying rolling peak; gpuThrottling flags a
//             GPU clock held below that peak while thermal pressure has risen.
//
import Foundation
import Observation
import SiliconScopeCore

@MainActor
@Observable
final class SiliconScopeMonitor {
    /// Rolling time-series for sparklines (last ~60 samples per series).
    struct History {
        var soc: [Double] = []
        var pCPU: [Double] = []        // 0...1
        var gpu: [Double] = []         // 0...1
        var bandwidth: [Double] = []   // GB/s
        var dieTemp: [Double] = []     // Celsius
        var memory: [Double] = []      // GB used
        var netDown: [Double] = []     // bytes/s
        var netUp: [Double] = []       // bytes/s
        var diskRead: [Double] = []    // bytes/s
        var diskWrite: [Double] = []   // bytes/s

        mutating func push(_ s: SystemSnapshot) {
            roll(&soc, s.power.socWatts)
            roll(&pCPU, s.cpu.pUsage)
            roll(&gpu, s.gpu.usage)
            roll(&bandwidth, s.bandwidth.totalGBs)
            roll(&dieTemp, s.temperature.cpuCelsius)
            roll(&memory, s.memory.usedGB)
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

    private(set) var snapshot = SystemSnapshot()
    private(set) var history = History()
    let topology: CPUTopology?

    // Chip-agnostic bar scaling: track observed peaks instead of hardcoding per-chip
    // maxima (bandwidth and GPU max differ across M1/Pro/Max/Ultra/M2/M3/M4).
    private(set) var bandwidthPeakGBs: Double = 80
    private(set) var mediaPeakGBs: Double = 2
    private(set) var anePeakWatts: Double = 2

    // Rolling peak GPU clock (MHz), basis for throttle detection. Decays slowly so a
    // brief boost doesn't pin it forever, yet it outlasts a sustained throttle — unlike
    // a short-window max, which would normalize the suppressed clock as the new peak.
    private(set) var gpuClockPeakMHz: Double = 0
    private static let gpuClockPeakDecay = 0.999

    private let sampler = SystemSampler()
    private var loopTask: Task<Void, Never>?

    init() {
        topology = sampler.topology
    }

    /// True when the GPU clock is held well below its rolling peak while the GPU is
    /// active and thermal pressure has risen above nominal — i.e. thermal throttling.
    /// The clock-drop guard distinguishes a real throttle from ordinary DVFS idle (a
    /// low clock with no work), and the usage guard keeps an idle GPU from tripping it.
    var gpuThrottling: Bool {
        guard gpuClockPeakMHz > 0 else { return false }
        return snapshot.gpu.usage > 0.3
            && snapshot.thermal.pressure != .nominal
            && snapshot.gpu.freqMHz < 0.85 * gpuClockPeakMHz
    }

    /// How far the current GPU clock sits below its rolling peak (0...1; 0 when at/above).
    var gpuClockDropFraction: Double {
        guard gpuClockPeakMHz > 0, snapshot.gpu.freqMHz < gpuClockPeakMHz else { return 0 }
        return 1 - snapshot.gpu.freqMHz / gpuClockPeakMHz
    }

    /// Unified-memory bandwidth ceiling (GB/s). The per-chip spec value, raised to the
    /// observed peak if traffic ever exceeds it (so the figure never under-reports and
    /// still works on chips missing from the table).
    var bandwidthCeilingGBs: Double {
        let spec = topology.map { Bottleneck.bandwidthCeilingGBs(chipName: $0.chipName, pCoreCount: $0.pCoreCount) } ?? 0
        return max(spec, bandwidthPeakGBs)
    }

    /// Current total unified-memory bandwidth as a fraction of the ceiling (0...1).
    var bandwidthPercentOfCeiling: Double {
        let ceiling = bandwidthCeilingGBs
        return ceiling > 0 ? min(1, snapshot.bandwidth.totalGBs / ceiling) : 0
    }

    /// The single dominant AI-workload bottleneck right now (hero feature verdict).
    var bottleneck: Bottleneck {
        Bottleneck.classify(snapshot, ceilingGBs: bandwidthCeilingGBs, throttling: gpuThrottling)
    }

    // Memory-pressure precursor: rate deltas of the lifetime VM counters (pages/sec).
    // Mirrors gpuClockPeakMHz tracking — the static budget risk lives in Core, the
    // temporal refinement (the real "before tokens/sec collapses" signal) lives here.
    private var previousMem: (compressions: UInt64, swapins: UInt64, swapouts: UInt64, timeNs: UInt64)?
    private(set) var memorySwapRate: Double = 0          // (swapins + swapouts) pages/sec
    private(set) var memoryCompressionRate: Double = 0   // compressions pages/sec
    private static let compressionRatePagesPerSec = 200.0

    // Opt-in runtime API (③): polled on its own cadence behind UserDefaults
    // "aiRuntimeAPIEnabled". Default OFF — the task is never spawned until enabled.
    private let apiClient = RuntimeAPIClient()
    private var apiPollTask: Task<Void, Never>?
    private(set) var runtimeAPI = RuntimeAPISample()
    private static let apiCadenceSeconds = 2.5

    /// Refined memory risk: the static budget baseline plus live swap/compression rates.
    /// swapping ⇐ active swap I/O (or the static baseline); tight ⇐ compression rising
    /// while headroom is nearly gone — catches the collapse before static used% would.
    var memoryRisk: MemoryBudget.Risk {
        let base = snapshot.memoryBudget.risk
        if base == .swapping || memorySwapRate > 0 { return .swapping }
        if memoryCompressionRate > Self.compressionRatePagesPerSec
            && snapshot.memoryBudget.headroomNowBytes < (1 << 30) {
            return .tight
        }
        return base
    }

    func start() {
        guard loopTask == nil else { return }
        // C5: clear rate state so the first tick after (re)start emits no spurious delta.
        previousMem = nil
        memorySwapRate = 0
        memoryCompressionRate = 0
        let sampler = sampler
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let sampled = await Task.detached(priority: .utility) {
                    sampler.sample(interval: 0.2)
                }.value
                guard let self else { return }
                // Opt-in runtime API: pull the key each tick and lazily start/stop polling.
                if UserDefaults.standard.bool(forKey: "aiRuntimeAPIEnabled") {
                    self.startAPIPollingIfNeeded()
                } else {
                    self.stopAPIPolling()
                }
                var snap = sampled
                snap.runtimeAPI = self.effectiveRuntimeAPI()    // C4 staleness applied
                self.snapshot = snap
                self.bandwidthPeakGBs = max(self.bandwidthPeakGBs, snap.bandwidth.totalGBs)
                self.mediaPeakGBs = max(self.mediaPeakGBs, snap.bandwidth.mediaGBs)
                self.anePeakWatts = max(self.anePeakWatts, snap.power.aneWatts)
                self.gpuClockPeakMHz = max(snap.gpu.freqMHz, self.gpuClockPeakMHz * Self.gpuClockPeakDecay)
                self.updateMemoryRates(snap)
                self.history.push(snap)
                let interval = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 1.0
                try? await Task.sleep(for: .seconds(max(0.3, interval)))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        stopAPIPolling()
        // C5: drop rate state so a later restart doesn't diff across the pause.
        previousMem = nil
        memorySwapRate = 0
        memoryCompressionRate = 0
    }

    // MARK: - Opt-in runtime API polling

    /// C4: a poll result older than 3× cadence is downgraded to .unreachable so the UI
    /// never shows a frozen tokens/sec from a wedged poll.
    private func effectiveRuntimeAPI() -> RuntimeAPISample {
        var s = runtimeAPI
        if s.status == .ok, let updated = s.lastUpdated,
           Date().timeIntervalSince(updated) > 3 * Self.apiCadenceSeconds {
            s.status = .unreachable
        }
        return s
    }

    private struct ProbeInputs {
        let kind: AIRuntimeKind?
        let ollamaEmbedded: Int?
        let ollamaPort: Int
        let lmStudioPort: Int
    }

    /// Captured under a brief main-actor hold, so the poll task doesn't retain the monitor
    /// across the network call (avoids a retain cycle and a frozen monitor).
    private func currentProbeInputs() -> ProbeInputs {
        ProbeInputs(kind: snapshot.aiRuntime.primaryKind,
                    ollamaEmbedded: snapshot.aiRuntime.ollamaEmbeddedPort,
                    ollamaPort: Self.port(forKey: "aiRuntimeOllamaPort", default: 11434),
                    lmStudioPort: Self.port(forKey: "aiRuntimeLMStudioPort", default: 1234))
    }

    private func startAPIPollingIfNeeded() {
        guard apiPollTask == nil else { return }
        let client = apiClient
        apiPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let inputs = self?.currentProbeInputs() else { return }
                let result = await client.probe(primaryKind: inputs.kind,
                                                ollamaEmbeddedPort: inputs.ollamaEmbedded,
                                                ollamaPort: inputs.ollamaPort,
                                                lmStudioPort: inputs.lmStudioPort)
                self?.runtimeAPI = result
                try? await Task.sleep(for: .seconds(Self.apiCadenceSeconds))
            }
        }
    }

    private func stopAPIPolling() {
        guard apiPollTask != nil else { return }
        apiPollTask?.cancel()
        apiPollTask = nil
        runtimeAPI = RuntimeAPISample()   // back to .disabled
    }

    private static func port(forKey key: String, default def: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : def
    }

    /// Diffs the lifetime VM counters into pages/sec rates (guards against counter resets).
    private func updateMemoryRates(_ snap: SystemSnapshot) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let m = snap.memory
        defer { previousMem = (m.compressions, m.swapins, m.swapouts, nowNs) }
        guard let prev = previousMem, nowNs > prev.timeNs else {
            memorySwapRate = 0
            memoryCompressionRate = 0
            return
        }
        let secs = Double(nowNs - prev.timeNs) / 1_000_000_000
        guard secs > 0 else { return }
        func delta(_ now: UInt64, _ was: UInt64) -> Double { now >= was ? Double(now - was) : 0 }
        memorySwapRate = (delta(m.swapins, prev.swapins) + delta(m.swapouts, prev.swapouts)) / secs
        memoryCompressionRate = delta(m.compressions, prev.compressions) / secs
    }
}
