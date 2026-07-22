//
//  File:      DashboardState.swift
//  Created:   2026-06-25
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The exact set of values DashboardView renders — built either from the live monitor
//             or from a replayed recording frame. Making it one value struct (rather than a
//             protocol) keeps "live and replay are the same shape" a compile-time fact and avoids
//             Observation pitfalls with existentials.
//  Notes:     The live-only display fields (benchmark) are zero/nil in replay; the live-only
//             actions (benchmark, process kill) are gated in DashboardView by whether an
//             onBenchmark closure was supplied. Built fresh inside a view body so @Observable /
//             playhead changes re-render.
//
import Foundation
import SiliconScopeCore

struct DashboardState {
    let snapshot: SystemSnapshot
    let topology: CPUTopology?
    let history: MetricsEngine.History
    let bottleneck: Bottleneck
    let bandwidthCeilingGBs: Double
    let bandwidthPeakGBs: Double
    let mediaPeakGBs: Double
    let anePeakWatts: Double
    let gpuClockDropFraction: Double
    let gpuThrottling: Bool
    let cpuClockDropFraction: Double
    let cpuThrottling: Bool
    let memoryRisk: MemoryBudget.Risk
    // Live-only display (nil/false in replay).
    let isBenchmarking: Bool
    let benchmark: BenchmarkRecord?
    let benchmarkError: String?

    /// Live: read the monitor's current snapshot + derived state.
    @MainActor init(live m: SiliconScopeMonitor) {
        snapshot = m.snapshot
        topology = m.topology
        history = m.history
        bottleneck = m.bottleneck
        bandwidthCeilingGBs = m.bandwidthCeilingGBs
        bandwidthPeakGBs = m.bandwidthPeakGBs
        mediaPeakGBs = m.mediaPeakGBs
        anePeakWatts = m.anePeakWatts
        gpuClockDropFraction = m.gpuClockDropFraction
        gpuThrottling = m.gpuThrottling
        cpuClockDropFraction = m.cpuClockDropFraction
        cpuThrottling = m.cpuThrottling
        memoryRisk = m.memoryRisk
        isBenchmarking = m.isBenchmarking
        benchmark = m.benchmarkForCurrentModel
        benchmarkError = m.benchmarkError
    }

    /// Replay: reconstruct the dashboard as it stood at frame `index` of a recording, using the
    /// precomputed peaks/rates + a rebuilt history window, run through the SAME verdict functions.
    init(replay rec: LoadedRecording, at index: Int) {
        let i = min(max(index, 0), max(0, rec.count - 1))
        let s = rec.frames.isEmpty ? SystemSnapshot() : rec.frames[i].snapshot
        let d = rec.derived.isEmpty ? DerivedScalars() : rec.derived[i]
        let h = rec.historyWindow(upTo: i)
        snapshot = s
        topology = rec.meta.topology
        history = h
        bandwidthPeakGBs = d.bandwidthPeakGBs
        mediaPeakGBs = d.mediaPeakGBs
        anePeakWatts = d.anePeakWatts
        let throttling = MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: d.gpuClockPeakMHz)
        gpuThrottling = throttling
        gpuClockDropFraction = MetricsEngine.gpuClockDropFraction(latest: s, gpuClockPeakMHz: d.gpuClockPeakMHz)
        cpuThrottling = MetricsEngine.cpuThrottling(latest: s, topology: rec.meta.topology)
        cpuClockDropFraction = MetricsEngine.cpuClockDropFraction(latest: s, topology: rec.meta.topology)
        bandwidthCeilingGBs = MetricsEngine.bandwidthCeiling(topology: rec.meta.topology, bandwidthPeakGBs: d.bandwidthPeakGBs)
        bottleneck = MetricsEngine.bottleneck(latest: s, history: h, bandwidthPeakGBs: d.bandwidthPeakGBs, throttling: throttling)
        memoryRisk = MetricsEngine.memoryRisk(latest: s, swapOutRate: d.memorySwapOutRate, compressionRate: d.memoryCompressionRate)
        isBenchmarking = false
        benchmark = nil
        benchmarkError = nil
    }

    /// Remote: reconstruct the dashboard from a remote Mac's wire metrics, run through the SAME
    /// verdict functions as replay. History is empty (no time series over the wire yet) → flat
    /// sparklines. Powers the remote-mode DashboardView so a remote Mac looks like This Mac.
    init(remote m: MachineMetrics) {
        let (s, topo) = m.toDashboardSnapshot()
        snapshot = s
        topology = topo
        history = MetricsEngine.History()
        anePeakWatts = m.apple?.anePeakWatts ?? 0
        mediaPeakGBs = m.apple?.mediaPeakGBs ?? 0
        // Prefer the agent's decaying observed peak; fall back to the current total on version skew.
        bandwidthPeakGBs = m.apple?.bandwidth.totalPeakGBs ?? m.apple?.bandwidth.totalGBs ?? 0
        let throttling = MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 0)
        gpuThrottling = throttling
        gpuClockDropFraction = 0
        cpuThrottling = false
        cpuClockDropFraction = 0
        bandwidthCeilingGBs = MetricsEngine.bandwidthCeiling(topology: topo, bandwidthPeakGBs: bandwidthPeakGBs)
        bottleneck = MetricsEngine.bottleneck(latest: s, history: history, bandwidthPeakGBs: bandwidthPeakGBs, throttling: throttling)
        memoryRisk = MetricsEngine.memoryRisk(latest: s, swapOutRate: 0, compressionRate: 0)
        isBenchmarking = false
        benchmark = nil
        benchmarkError = nil
    }
}
