//
//  File:      DashboardState.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
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
        memoryRisk = m.memoryRisk
        isBenchmarking = m.isBenchmarking
        benchmark = m.benchmarkForCurrentModel
        benchmarkError = m.benchmarkError
    }
}
