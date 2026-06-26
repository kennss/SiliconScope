//
//  File:      SystemSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
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

    // Peripheral battery (Magic/AirPods): heavier than a 1 s tick (IORegistry scan + a
    // ~0.2 s system_profiler), so sample on a short cadence and reuse between ticks. 5 s keeps a
    // newly-connected device appearing quickly without polling system_profiler every second.
    private let peripheralSampler = PeripheralBatterySampler()
    private var cachedPeripherals: [PeripheralBattery] = []
    private var lastPeripheralSample: Date = .distantPast
    private let peripheralInterval: TimeInterval = 5

    public init() {
        let topology = cpu?.topology
        gpu = topology.flatMap { GPUSampler(topology: $0) }
        let coreCount = topology.map { $0.eCoreCount + $0.pCoreCount } ?? 0
        temperature = TemperatureSampler(coreCount: coreCount)
    }

    public var topology: CPUTopology? { cpu?.topology }

    /// Produces one full snapshot. The four delta samplers (power, CPU, GPU, bandwidth) each
    /// sleep `interval` internally; they run CONCURRENTLY here, so this blocks for roughly
    /// `interval` instead of 4 × `interval`. The remaining samplers are instant reads. Still call
    /// off the main thread (it blocks ~interval).
    public func sample(interval: TimeInterval = 0.2) -> SystemSnapshot {
        var snapshot = SystemSnapshot()

        // Run the four sleep-based samplers in parallel. Each closure touches only its own
        // (non-Sendable) sampler and writes one Sendable result into the lock-protected box —
        // safe despite @unchecked Sendable, and they never run concurrently with themselves
        // (one serial tick at a time).
        let io = OSAllocatedUnfairLock(initialState: IOResults())
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        func parallel(_ work: @escaping @Sendable () -> Void) {
            group.enter(); queue.async { work(); group.leave() }
        }
        parallel { let r = self.power?.sample(interval: interval) ?? PowerSample(); io.withLock { $0.power = r } }
        parallel { let r = self.cpu?.sample(interval: interval) ?? CPUSample(); io.withLock { $0.cpu = r } }
        parallel { let r = self.gpu?.sample(interval: interval) ?? GPUSample(); io.withLock { $0.gpu = r } }
        parallel { let r = self.bandwidth?.sample(interval: interval) ?? BandwidthSample(); io.withLock { $0.bandwidth = r } }
        group.wait()
        let r = io.withLock { $0 }
        snapshot.power = r.power
        snapshot.cpu = r.cpu
        snapshot.gpu = r.gpu
        snapshot.bandwidth = r.bandwidth

        snapshot.memory = memory.sample()
        snapshot.thermal = thermal.sample()
        snapshot.temperature = temperature.sample()
        snapshot.network = network.sample()
        snapshot.disk = disk.sample()
        snapshot.battery = battery.sample()
        snapshot.peripherals = sampledPeripherals()
        snapshot.processes = processes.sample()   // full set; UI sorts/filters/limits
        snapshot.aiRuntime = aiRuntime.sample(from: snapshot.processes)
        // Budget after detection so the resident runtime's RSS lifts `loadable`
        // (pure arithmetic on the already-taken memory sample — no extra syscalls/sleep).
        snapshot.memoryBudget = MemoryBudget.estimate(
            memory: snapshot.memory,
            activeRuntimeRSS: snapshot.aiRuntime.primaryMemoryBytes
        )
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
}
