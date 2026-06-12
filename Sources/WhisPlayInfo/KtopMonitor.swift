//
//  File:      KtopMonitor.swift
//  Created:   2026-06-08
//  Updated:   2026-06-12
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
import KtopCore

@MainActor
@Observable
final class KtopMonitor {
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

    func start() {
        guard loopTask == nil else { return }
        let sampler = sampler
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let snap = await Task.detached(priority: .utility) {
                    sampler.sample(interval: 0.2)
                }.value
                guard let self else { return }
                self.snapshot = snap
                self.bandwidthPeakGBs = max(self.bandwidthPeakGBs, snap.bandwidth.totalGBs)
                self.mediaPeakGBs = max(self.mediaPeakGBs, snap.bandwidth.mediaGBs)
                self.anePeakWatts = max(self.anePeakWatts, snap.power.aneWatts)
                self.gpuClockPeakMHz = max(snap.gpu.freqMHz, self.gpuClockPeakMHz * Self.gpuClockPeakDecay)
                self.history.push(snap)
                let interval = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 1.0
                try? await Task.sleep(for: .seconds(max(0.3, interval)))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
