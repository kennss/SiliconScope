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
    private(set) var snapshot = SystemSnapshot()
    let topology: CPUTopology?

    // All path-dependent derivation (sparkline history, decaying peaks, memory rates, and the
    // throttle / ceiling / bottleneck / memory-risk verdicts) lives in MetricsEngine so the live
    // monitor and session replay share identical logic. The monitor delegates every derived value.
    private let engine: MetricsEngine
    private var lastIngest: DispatchTime?

    var history: MetricsEngine.History { engine.history }
    var bandwidthPeakGBs: Double { engine.bandwidthPeakGBs }
    var mediaPeakGBs: Double { engine.mediaPeakGBs }
    var anePeakWatts: Double { engine.anePeakWatts }
    var gpuClockPeakMHz: Double { engine.gpuClockPeakMHz }
    var gpuThrottling: Bool { engine.gpuThrottling }
    var gpuClockDropFraction: Double { engine.gpuClockDropFraction }
    var bandwidthCeilingGBs: Double { engine.bandwidthCeilingGBs }
    var bandwidthPercentOfCeiling: Double { engine.bandwidthPercentOfCeiling }
    var bottleneck: Bottleneck { engine.bottleneck }
    var memoryRisk: MemoryBudget.Risk { engine.memoryRisk }
    var memoryPageInRate: Double { engine.memoryPageInRate }
    var memoryPageOutRate: Double { engine.memoryPageOutRate }
    var memorySwapInRate: Double { engine.memorySwapInRate }
    var memorySwapOutRate: Double { engine.memorySwapOutRate }
    var memoryCompressionRate: Double { engine.memoryCompressionRate }

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

    // Process Inspector: while a pid is focused, sample just that pid each loop tick (cheap — a few
    // syscalls on one pid) using the same dt. focusEnded flags that the focused process exited.
    var focusedPID: Int32?
    private(set) var focusedDetail: ProcessDetail?
    private(set) var focusedHistory = ProcessDetailHistory()
    private(set) var focusEnded = false
    private var focusSampler: ProcessDetailSampler?

    init() {
        topology = sampler.topology
        engine = MetricsEngine(topology: sampler.topology)
        benchmarks = Self.loadBenchmarks()
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

    func start() {
        guard loopTask == nil else { return }
        // C5: clear rate state so the first tick after (re)start emits no spurious delta.
        engine.reset(); lastIngest = nil
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
                // Advance the derivation engine first (folds peaks, rates, history), then publish
                // the snapshot — so the Observation-triggered re-render reads fresh engine state.
                let now = DispatchTime.now()
                let dt = self.lastIngest.map { Double(now.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 } ?? 0
                self.lastIngest = now
                self.engine.ingest(snap, dt: dt)
                self.snapshot = snap
                if self.isRecording {
                    self.recorder.append(snap)                       // 1 Hz self-gated inside
                    self.recordingSampleCount = self.recorder.sampleCount
                }
                if let sampler = self.focusSampler {                 // Process Inspector (same dt)
                    if let d = sampler.sample(dt: dt) {
                        self.focusedDetail = d
                        self.focusedHistory.push(d)
                    } else {
                        self.focusEnded = true                       // focused process exited
                        self.focusSampler = nil
                    }
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
        endFocus()
        // C5: drop rate state so a later restart doesn't diff across the pause.
        engine.reset(); lastIngest = nil
    }

    // MARK: - Session recording (Phase 1)

    /// Starts capturing snapshots to a temp .ssrec. No-op if already recording or on failure.
    func startRecording() {
        guard !isRecording else { return }
        do {
            try recorder.start(topology: topology)
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

    // MARK: - Process Inspector

    /// Focus a pid: a fresh sampler + history; the loop samples it each tick until endFocus().
    func focus(_ pid: Int32) {
        focusedPID = pid
        focusSampler = ProcessDetailSampler(pid: pid)
        focusedHistory = ProcessDetailHistory()
        focusedDetail = nil
        focusEnded = false
    }

    /// Stop inspecting (also clears the captured detail/history).
    func endFocus() {
        focusedPID = nil
        focusSampler = nil
        focusedDetail = nil
        focusedHistory = ProcessDetailHistory()
        focusEnded = false
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

}

/// Mutable power-sample accumulator shared between runBenchmark and its power-probe task.
/// Both touch it only on the main actor, so the unchecked Sendable conformance is safe.
private final class WattBox: @unchecked Sendable {
    var watts: [Double] = []
    var done = false
}
