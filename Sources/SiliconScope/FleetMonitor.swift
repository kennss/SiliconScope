//
//  File:      FleetMonitor.swift
//  Created:   2026-07-21
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The Mac-side fleet aggregator: owns mDNS discovery (FleetDiscovery), holds the set of
//             discovered machines, and polls each on an interval for the latest MachineMetrics (or
//             an error). UI-side (@Observable, @MainActor); it consumes the source-agnostic
//             MachineMetrics boundary, so the transport (HTTP now; paired agent-push later) is
//             swappable without touching this or the view.
//  Notes:     Sources are DYNAMIC — discovery adds/removes them as agents appear/vanish, preserving
//             a machine's last metrics across a source refresh. Fetches run OFF the main actor
//             (task-group child tasks are non-isolated) so no transport stalls the UI.
//
import Foundation
import Observation
import SiliconScopeCore

@MainActor
@Observable
final class FleetMonitor {
    struct Entry: Identifiable {
        let source: any FleetSource
        var id: String { source.id }
        var metrics: MachineMetrics? = nil
        var error: String? = nil
        var lastUpdated: Date? = nil
        var needsPairing: Bool = false   // agent returned 401 — user must enter its token
    }

    /// One point in a machine's rolling history, for the detail view's sparklines.
    struct Sample: Identifiable {
        let id: Int          // monotonic sequence (stable Chart identity)
        let t: Date
        let cpu: Double      // 0..100
        let gpuUtil: Double  // 0..100 (first GPU; 0 if none)
        let gpuPowerW: Double
        let memFrac: Double  // 0..1
    }

    private(set) var entries: [Entry] = []
    private(set) var history: [String: [Sample]] = [:]   // machine id → rolling samples
    @ObservationIgnored private let historyLimit = 120    // ~6 min at 3s
    @ObservationIgnored private var sampleSeq = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var discovery: FleetDiscovery?

    init(interval: TimeInterval = 3) {
        self.interval = interval
    }

    func start() {
        if discovery == nil {
            discovery = FleetDiscovery { [weak self] sources in self?.setSources(sources) }
        }
        discovery?.start()
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(for: .seconds(self?.interval ?? 3))
            }
        }
    }

    func stop() {
        discovery?.stop()
        task?.cancel()
        task = nil
    }

    /// Replace the source set (from discovery), keeping the last metrics for machines that persist.
    func setSources(_ sources: [any FleetSource]) {
        entries = sources.map { src in
            if let existing = entries.first(where: { $0.id == src.id }) {
                return Entry(source: src, metrics: existing.metrics,
                             error: existing.error, lastUpdated: existing.lastUpdated,
                             needsPairing: existing.needsPairing)
            }
            return Entry(source: src)
        }
        .sorted { $0.source.label.localizedCaseInsensitiveCompare($1.source.label) == .orderedAscending }
    }

    /// Store a machine's pairing token, rebuild its source with the token applied, and re-poll now.
    func pair(name: String, token: String) {
        FleetPairingStore.setToken(token, for: name)
        discovery?.rebuild()
        Task { await pollAll() }
    }

    /// Forget a machine's pairing token (it reverts to "pairing required").
    func unpair(name: String) {
        FleetPairingStore.removeToken(for: name)
        discovery?.rebuild()
    }

    private func pollAll() async {
        let sources = entries.map(\.source)
        await withTaskGroup(of: (String, Result<MachineMetrics, Error>).self) { group in
            for src in sources {
                group.addTask {
                    do { return (src.id, .success(try await src.fetch())) }
                    catch { return (src.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard let i = entries.firstIndex(where: { $0.id == id }) else { continue }
                switch result {
                case .success(let m):
                    entries[i].metrics = m
                    entries[i].error = nil
                    entries[i].needsPairing = false
                    entries[i].lastUpdated = Date()
                    appendHistory(id: id, m: m)
                case .failure(let e):
                    entries[i].error = String(describing: e)
                    if case FleetFetchError.unauthorized = e { entries[i].needsPairing = true }
                }
            }
        }
    }

    /// Append one rolling-history sample for a machine, trimming to the recent window.
    private func appendHistory(id: String, m: MachineMetrics) {
        sampleSeq += 1
        let memFrac = m.memory.totalBytes > 0 ? Double(m.memory.usedBytes) / Double(m.memory.totalBytes) : 0
        let sample = Sample(id: sampleSeq, t: Date(),
                            cpu: m.cpu.usagePercent,
                            gpuUtil: m.gpus.first?.utilizationPercent ?? 0,
                            gpuPowerW: m.gpus.first?.powerDrawW ?? 0,
                            memFrac: memFrac)
        var buf = history[id, default: []]
        buf.append(sample)
        if buf.count > historyLimit { buf.removeFirst(buf.count - historyLimit) }
        history[id] = buf
    }
}
