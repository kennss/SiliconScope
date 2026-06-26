//
//  File:      SiliconScopeMonitor.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
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
        var eCPU: [Double] = []        // 0...1
        var gpu: [Double] = []         // 0...1
        var gpuMem: [Double] = []      // 0...1 (GPU in-use memory / total unified memory)
        var ane: [Double] = []         // Watts
        var media: [Double] = []       // GB/s (Media Engine)
        var bandwidth: [Double] = []   // GB/s
        var dieTemp: [Double] = []     // Celsius
        var memory: [Double] = []      // GB used
        var memFraction: [Double] = [] // 0...1 (used / total) — plotted on a fixed 0...1 axis
        var netDown: [Double] = []     // bytes/s
        var netUp: [Double] = []       // bytes/s
        var diskRead: [Double] = []    // bytes/s
        var diskWrite: [Double] = []   // bytes/s

        mutating func push(_ s: SystemSnapshot) {
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
    // Same slow decay for the bandwidth / media / ANE peaks that normalize the menu-bar
    // glyph + trend graphs (and the bandwidth-bound verdict): a new high is adopted
    // instantly, otherwise the peak decays toward a floor so a one-off spike never pins the
    // scale and it self-calibrates to whatever the chip actually achieves (M1…M5+).
    private static let peakDecay = 0.999

    private let sampler = SystemSampler()
    private var loopTask: Task<Void, Never>?

    // Session recording (Phase 1): the recorder streams full snapshots to a temp .ssrec. These
    // mirror its state into @Observable properties so the RecordBar reflects start/stop and the
    // live sample count immediately. cadence:0 = record EVERY sample tick, so the recording rate
    // follows the user's sample-interval setting (the loop's own cadence) rather than a fixed gate.
    private let recorder = SessionRecorder(cadence: 0)
    private(set) var isRecording = false
    private(set) var recordingSampleCount = 0
    private(set) var hasRecording = false              // a finished recording exists to export
    var recordingElapsed: TimeInterval { recorder.elapsed }
    var recordingFileURL: URL? { recorder.fileURL }

    init() {
        topology = sampler.topology
        benchmarks = Self.loadBenchmarks()
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
    /// Classified on a short rolling average of GPU% and bandwidth so the verdict doesn't
    /// flicker when the GPU oscillates sample-to-sample (e.g. 69%↔100% during decode).
    var bottleneck: Bottleneck {
        Bottleneck.classify(memoryCritical: snapshot.memory.pressure == .critical,
                            gpuUsage: Self.tailAverage(history.gpu, count: 3, fallback: snapshot.gpu.usage),
                            bandwidthGBs: Self.tailAverage(history.bandwidth, count: 3, fallback: snapshot.bandwidth.totalGBs),
                            achievableGBs: bandwidthPeakGBs,
                            throttling: gpuThrottling)
    }

    private static func tailAverage(_ values: [Double], count: Int, fallback: Double) -> Double {
        let tail = values.suffix(count)
        return tail.isEmpty ? fallback : tail.reduce(0, +) / Double(tail.count)
    }

    // Memory-pressure precursor: rate deltas of the lifetime VM counters (pages/sec).
    // Mirrors gpuClockPeakMHz tracking — the static budget risk lives in Core, the
    // temporal refinement (the real "before tokens/sec collapses" signal) lives here.
    private struct MemCounters { let pageins, pageouts, swapins, swapouts, compressions, timeNs: UInt64 }
    private var previousMem: MemCounters?
    private(set) var memoryPageInRate: Double = 0        // pages/sec (PAGES panel)
    private(set) var memoryPageOutRate: Double = 0
    private(set) var memorySwapInRate: Double = 0        // recovery reads (normal)
    private(set) var memorySwapOutRate: Double = 0       // swapouts/sec — eviction under pressure
    private(set) var memoryCompressionRate: Double = 0   // compressions pages/sec
    private static let compressionRatePagesPerSec = 200.0

    private func resetMemoryRates() {
        previousMem = nil
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }

    // Opt-in runtime API (③): polled on its own cadence behind UserDefaults
    // "aiRuntimeAPIEnabled". Default OFF — the task is never spawned until enabled.
    private let apiClient = RuntimeAPIClient()
    private var apiPollTask: Task<Void, Never>?
    private(set) var runtimeAPI = RuntimeAPISample()
    private static let apiCadenceSeconds = 2.5

    // On-demand benchmark (tok/s + tokens-per-watt), persisted per model.
    private(set) var isBenchmarking = false
    private(set) var benchmarks: [BenchmarkRecord] = []
    private(set) var benchmarkError: String?
    private static let benchmarksKey = "benchmarkRecords"

    // Threshold-alert notifications (opt-in "notificationsEnabled"): edge-triggered so a
    // condition fires once when it starts, with a per-condition cooldown against flapping.
    private var notifiedConditions: Set<String> = []
    private var lastNotified: [String: Date] = [:]
    private static let notifyCooldown: TimeInterval = 300   // 5 min per condition

    /// Refined memory risk: the static budget baseline plus live swap/compression rates.
    /// swapping ⇐ active swap I/O (or the static baseline); tight ⇐ compression rising
    /// while headroom is nearly gone — catches the collapse before static used% would.
    var memoryRisk: MemoryBudget.Risk {
        let base = snapshot.memoryBudget.risk
        if base == .swapping || memorySwapOutRate > 0 { return .swapping }
        if memoryCompressionRate > Self.compressionRatePagesPerSec
            && snapshot.memoryBudget.headroomNowBytes < (1 << 30) {
            return .tight
        }
        return base
    }

    func start() {
        guard loopTask == nil else { return }
        // C5: clear rate state so the first tick after (re)start emits no spurious delta.
        resetMemoryRates()
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
                self.bandwidthPeakGBs = max(snap.bandwidth.totalGBs, max(40, self.bandwidthPeakGBs * Self.peakDecay))
                self.mediaPeakGBs = max(snap.bandwidth.mediaGBs, max(1, self.mediaPeakGBs * Self.peakDecay))
                self.anePeakWatts = max(snap.power.aneWatts, max(1, self.anePeakWatts * Self.peakDecay))
                self.gpuClockPeakMHz = max(snap.gpu.freqMHz, self.gpuClockPeakMHz * Self.gpuClockPeakDecay)
                self.updateMemoryRates(snap)
                self.history.push(snap)
                if self.isRecording {
                    self.recorder.append(snap)                       // 1 Hz self-gated inside
                    self.recordingSampleCount = self.recorder.sampleCount
                }
                self.checkAlertsAndNotify()
                MetricBarController.shared.sync(monitor: self)
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
        resetMemoryRates()
    }

    // MARK: - Session recording (Phase 1)

    /// Starts capturing snapshots to a temp .ssrec. No-op if already recording or on failure.
    func startRecording() {
        guard !isRecording else { return }
        do {
            try recorder.start()
            isRecording = true
            recordingSampleCount = 0
            hasRecording = false
        } catch {
            isRecording = false
        }
    }

    /// Stops capturing; the recording stays on disk, ready to export.
    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        hasRecording = recorder.fileURL != nil && recorder.sampleCount > 0
    }

    /// Exports the lossless JSONL recording (.ssrec) to `url`.
    func exportRecording(to url: URL) throws { try recorder.exportRecording(to: url) }

    /// Exports a flattened CSV of the recording to `url`.
    func exportRecordingCSV(to url: URL) throws { try recorder.exportCSV(to: url) }

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

    // MARK: - On-demand benchmark

    /// Runs one bounded generation against the active runtime and records decode tok/s plus
    /// the mean SoC package power over the run → tokens-per-watt. Needs the runtime API on
    /// (that's how we know the loaded model name). Idempotent while a run is in flight.
    func runBenchmark() async {
        guard !isBenchmarking else { return }
        guard let kind = snapshot.aiRuntime.primaryKind else {
            benchmarkError = "No local AI runtime detected"; return
        }
        guard let model = snapshot.runtimeAPI.primaryModel?.name, !model.isEmpty else {
            benchmarkError = "Enable “Connect to local AI runtimes” and load a model first"; return
        }
        let port = benchmarkPort(for: kind)
        let chip = topology?.chipName ?? "Apple Silicon"
        isBenchmarking = true
        benchmarkError = nil
        defer { isBenchmarking = false }

        // Sample SoC power while the generation runs. Everything here stays on the main
        // actor (the monitor loop keeps refreshing snapshot during the awaited network call).
        let box = WattBox()
        let powerProbe = Task { @MainActor [weak self] in
            while !box.done && !Task.isCancelled {
                // Only count samples while the GPU is actually decoding, so idle / ramp-up
                // power doesn't deflate the average (which would inflate tokens-per-watt).
                if let self, self.snapshot.gpu.usage > 0.4 {
                    box.watts.append(self.snapshot.power.socWatts)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        // 256 tokens keeps the decode running long enough that the ~1s power snapshots
        // capture steady-state draw (a 128-token run can finish before power ramps).
        let result = await BenchmarkClient().run(kind: kind, port: port, model: model, numPredict: 256)
        box.done = true
        powerProbe.cancel()

        guard let result else {
            benchmarkError = "Benchmark failed — is \(kind.displayName)'s local server reachable?"
            return
        }
        let avgW = box.watts.isEmpty ? snapshot.power.socWatts : box.watts.reduce(0, +) / Double(box.watts.count)
        let record = BenchmarkRecord(model: model, runtime: kind.displayName, chip: chip,
                                     tokensPerSec: result.tokensPerSec, avgWatts: avgW, timestamp: Date())
        benchmarks.removeAll { $0.runtime == record.runtime && $0.model == record.model }   // keep latest per model
        benchmarks.insert(record, at: 0)
        if benchmarks.count > 20 { benchmarks = Array(benchmarks.prefix(20)) }
        saveBenchmarks()
    }

    /// Most recent benchmark for the currently loaded model, if any.
    var benchmarkForCurrentModel: BenchmarkRecord? {
        guard let kind = snapshot.aiRuntime.primaryKind,
              let model = snapshot.runtimeAPI.primaryModel?.name else { return nil }
        return benchmarks.first { $0.runtime == kind.displayName && $0.model == model }
    }

    private func benchmarkPort(for kind: AIRuntimeKind) -> Int {
        switch kind {
        case .lmStudio: return Self.port(forKey: "aiRuntimeLMStudioPort", default: 1234)
        case .rapidMLX: return 8000
        case .llamaCpp: return snapshot.aiRuntime.ollamaEmbeddedPort ?? 8080
        default:        return Self.port(forKey: "aiRuntimeOllamaPort", default: 11434)
        }
    }

    private static func loadBenchmarks() -> [BenchmarkRecord] {
        guard let data = UserDefaults.standard.data(forKey: benchmarksKey),
              let recs = try? JSONDecoder().decode([BenchmarkRecord].self, from: data) else { return [] }
        return recs
    }
    private func saveBenchmarks() {
        if let data = try? JSONEncoder().encode(benchmarks) {
            UserDefaults.standard.set(data, forKey: Self.benchmarksKey)
        }
    }

    // MARK: - Threshold-alert notifications

    /// Posts a notification when an alert condition newly becomes active (edge-triggered),
    /// throttled per condition so a flapping signal can't spam. Same conditions as the
    /// menu-bar red blink: GPU thermal throttle, swapping, memory-pressure critical.
    private func checkAlertsAndNotify() {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else {
            notifiedConditions.removeAll(); return
        }
        var active: [(key: String, title: String, body: String)] = []
        if gpuThrottling {
            active.append(("throttle", "GPU thermal throttle",
                String(format: "GPU clock held %.0f%% below peak by heat — sustained performance limited.",
                       gpuClockDropFraction * 100)))
        }
        if memoryRisk == .swapping {
            active.append(("swap", "Memory swapping",
                "Unified memory is full — swapping is limiting throughput."))
        } else if snapshot.memory.pressure == .critical {
            active.append(("mempressure", "Memory pressure: critical", "Free up memory to avoid swapping."))
        }
        let now = Date()
        for a in active where !notifiedConditions.contains(a.key) {
            if let last = lastNotified[a.key], now.timeIntervalSince(last) < Self.notifyCooldown { continue }
            lastNotified[a.key] = now
            Notifier.post(title: a.title, body: a.body)
        }
        notifiedConditions = Set(active.map(\.key))
    }

    /// Diffs the lifetime VM counters into pages/sec rates (guards against counter resets).
    private func updateMemoryRates(_ snap: SystemSnapshot) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let m = snap.memory
        let cur = MemCounters(pageins: m.pageins, pageouts: m.pageouts, swapins: m.swapins,
                              swapouts: m.swapouts, compressions: m.compressions, timeNs: nowNs)
        defer { previousMem = cur }
        guard let prev = previousMem, nowNs > prev.timeNs else { resetRatesOnly(); return }
        let secs = Double(nowNs - prev.timeNs) / 1_000_000_000
        guard secs > 0 else { return }
        func delta(_ now: UInt64, _ was: UInt64) -> Double { now >= was ? Double(now - was) : 0 }
        memoryPageInRate  = delta(cur.pageins, prev.pageins)   / secs
        memoryPageOutRate = delta(cur.pageouts, prev.pageouts) / secs
        memorySwapInRate  = delta(cur.swapins, prev.swapins)   / secs
        // Only swapouts (eviction under pressure) signal a problem; swapins are recovery
        // reads of pages swapped earlier and must NOT trip the "swapping" warning.
        memorySwapOutRate = delta(cur.swapouts, prev.swapouts) / secs
        memoryCompressionRate = delta(cur.compressions, prev.compressions) / secs
    }

    /// Zeros the rates without touching previousMem (the caller's defer sets it).
    private func resetRatesOnly() {
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }
}

/// Mutable power-sample accumulator shared between runBenchmark and its power-probe task.
/// Both touch it only on the main actor, so the unchecked Sendable conformance is safe.
private final class WattBox: @unchecked Sendable {
    var watts: [Double] = []
    var done = false
}
