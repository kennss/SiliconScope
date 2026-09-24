//
//  File:      SystemSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Aggregates every SiliconScopeCore sampler into one SystemSnapshot. Intended
//             to run on a single background thread driven by the UI's refresh loop.
//  Notes:     @unchecked Sendable: the underlying samplers hold non-Sendable IOReport
//             handles, but SiliconScope only ever calls sample() from one serial background
//             task, so this is safe. Do not call sample() concurrently. The four delta/sleep
//             samplers (power/CPU/GPU/bandwidth) run in parallel within a single sample() call.
//
import Foundation
import os

public final class SystemSampler: @unchecked Sendable {
    /// Results of the four parallel delta samplers, gathered under a lock.
    private struct IOResults: Sendable {
        var power = PowerSample()
        var cpu = CPUSample()
        var gpu = GPUSample()
        var bandwidth = BandwidthSample()
    }

    private let power = PowerSampler()
    private let cpu = CPUSampler()
    private let gpu: GPUSampler?
    private let bandwidth = BandwidthSampler()
    private let memory = MemorySampler()
    private let thermal = ThermalSampler()
    private let temperature: TemperatureSampler
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let battery = BatterySampler()
    private let processes = ProcessSampler()
    private let aiRuntime = AIRuntimeSampler()

    // Peripheral battery (Magic/AirPods): heavier than a 1 s tick, so sample on a short cadence
    // and reuse between ticks. 5 s drives the cheap IORegistry HID scan (Magic Mouse/keyboard, and
    // where a newly-connected HID first appears — kept fast on purpose); the ~0.2 s system_profiler
    // (AirPods) is throttled separately to 30 s inside PeripheralBatterySampler (btTTL), so it is
    // NOT spawned every 5 s. (See docs/energy-optimization.md FIX 4.)
    private let peripheralSampler = PeripheralBatterySampler()
    private var cachedPeripherals: [PeripheralBattery] = []
    private var lastPeripheralSample: Date = .distantPast
    private let peripheralInterval: TimeInterval = 5

    // Process enumeration (proc_info over EVERY pid + proc_pidpath/proc_name + the AI-runtime
    // name/args scan) is the heaviest per-tick work — thousands of proc_info traps/sec on a busy
    // machine (measured ~23% of a core here, dominating the closed-window/menu-bar-only cost). It
    // does NOT need per-second freshness, so cache it on a slower cadence and reuse between ticks.
    // Correctness is safe: ProcessSampler normalizes CPU% by the ACTUAL wall-time delta, so a wider
    // gap just widens the interval. (See docs/energy-optimization.md FIX 5.)
    private var cachedProcesses: [ProcessRow] = []
    private var cachedAIRuntime = AIRuntimeSample()
    private var lastProcessSample: Date = .distantPast
    private let processInterval: TimeInterval = 2.5

    /// Not read through `cpu`: that sampler cannot construct on Intel (no IOReport).
    private let resolvedTopology = CPUTopology.detect()

    /// Whole-machine CPU usage for hosts without IOReport. Nil on Apple Silicon, where `cpu` serves.
    private let tickCPU: TickCPUSampler?

    public init() {
        gpu = cpu.flatMap { GPUSampler(topology: $0.topology) }
        temperature = TemperatureSampler(
            coreCount: resolvedTopology.eCoreCount + resolvedTopology.pCoreCount)
        tickCPU = cpu == nil ? TickCPUSampler() : nil
    }

    public var topology: CPUTopology? { resolvedTopology }

    /// Produces one snapshot, measuring only the groups in `demand`.
    ///
    /// The four delta samplers (power, CPU, GPU, bandwidth) each sleep `interval` internally; the
    /// demanded ones run CONCURRENTLY here, so this blocks for roughly `interval` instead of
    /// 4 × `interval` — and not at all when none of them is demanded. The remaining samplers are
    /// instant reads. Still call off the main thread (it blocks ~interval).
    ///
    /// ⚠️ A group outside `demand` is NOT measured, and the snapshot carries that group's
    /// zero-initialised default. Zeros are not readings: the caller must carry the previous value
    /// forward and tell `MetricsEngine.ingest` what was measured, or the history records a
    /// machine that went quiet. See MetricDemand.swift for the invariant.
    public func sample(interval: TimeInterval = 0.2, demand: MetricGroup = .all) -> SystemSnapshot {
        var snapshot = SystemSnapshot()

        // Run the demanded sleep-based samplers in parallel. Each closure touches only its own
        // (non-Sendable) sampler and writes one Sendable result into the lock-protected box —
        // safe despite @unchecked Sendable, and they never run concurrently with themselves
        // (one serial tick at a time).
        let io = OSAllocatedUnfairLock(initialState: IOResults())
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        func parallel(_ work: @escaping @Sendable () -> Void) {
            group.enter(); queue.async { work(); group.leave() }
        }
        if demand.contains(.power) {
            parallel { let r = self.power?.sample(interval: interval) ?? PowerSample(); io.withLock { $0.power = r } }
        }
        if demand.contains(.cpu) {
            parallel {
                var sample = self.cpu?.sample(interval: interval) ?? CPUSample()
                // No cluster split on Intel; mac() weights the P slot by core count.
                if let tick = self.tickCPU { sample.pUsage = tick.sampleUsage() }
                let r = sample
                io.withLock { $0.cpu = r }
            }
        }
        if demand.contains(.gpu) {
            parallel { let r = self.gpu?.sample(interval: interval) ?? GPUSample(); io.withLock { $0.gpu = r } }
        }
        if demand.contains(.bandwidth) {
            parallel { let r = self.bandwidth?.sample(interval: interval) ?? BandwidthSample(); io.withLock { $0.bandwidth = r } }
        }
        group.wait()
        let r = io.withLock { $0 }
        snapshot.power = r.power
        snapshot.cpu = r.cpu
        snapshot.gpu = r.gpu
        snapshot.bandwidth = r.bandwidth

        // The instant reads. Skipping one costs nothing to resume: the two that derive a RATE
        // (network, disk) divide by the ACTUAL elapsed nanoseconds since their last call, so a
        // wider gap widens the averaging window instead of inventing a spike.
        if demand.contains(.memory)      { snapshot.memory = memory.sample() }
        if demand.contains(.thermal)     { snapshot.thermal = thermal.sample() }
        if demand.contains(.temperature) { snapshot.temperature = temperature.sample() }
        if demand.contains(.network)     { snapshot.network = network.sample() }
        if demand.contains(.disk)        { snapshot.disk = disk.sample() }
        if demand.contains(.battery)     { snapshot.battery = battery.sample() }
        if demand.contains(.peripherals) { snapshot.peripherals = sampledPeripherals() }
        if demand.contains(.processes) {
            let procs = sampledProcesses()        // cached ~2.5 s (full set; UI sorts/filters/limits)
            snapshot.processes = procs.rows
            snapshot.aiRuntime = procs.aiRuntime
        } else {
            // Detection still reports the last table taken. The budget below reads its RSS, and a
            // menu-bar-only tick has no reason to re-walk every pid to refresh it.
            snapshot.aiRuntime = cachedAIRuntime
        }
        // Budget after detection so the resident runtime's RSS lifts `loadable`
        // (pure arithmetic on the already-taken memory sample — no extra syscalls/sleep).
        if demand.contains(.memory) {
            snapshot.memoryBudget = MemoryBudget.estimate(
                memory: snapshot.memory,
                activeRuntimeRSS: snapshot.aiRuntime.primaryMemoryBytes
            )
        }
        return snapshot
    }

    /// Peripheral battery on a slow cadence (re-sampled every `peripheralInterval`s, reused
    /// otherwise) so the per-second tick stays cheap.
    private func sampledPeripherals() -> [PeripheralBattery] {
        if Date().timeIntervalSince(lastPeripheralSample) >= peripheralInterval {
            lastPeripheralSample = Date()
            cachedPeripherals = peripheralSampler.sample()
        }
        return cachedPeripherals
    }

    /// Process table + AI-runtime detection on a slow cadence (re-sampled every `processInterval`s,
    /// reused otherwise) so the per-second tick stays cheap. CPU% stays correct (ProcessSampler
    /// normalizes by the real wall-time delta). The focused-process Inspector samples separately in
    /// the monitor loop, so it keeps updating every tick.
    private func sampledProcesses() -> (rows: [ProcessRow], aiRuntime: AIRuntimeSample) {
        if Date().timeIntervalSince(lastProcessSample) >= processInterval {
            lastProcessSample = Date()
            cachedProcesses = processes.sample()
            cachedAIRuntime = aiRuntime.sample(from: cachedProcesses)
        }
        return (cachedProcesses, cachedAIRuntime)
    }
}
