//
//  File:      MacAgent.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  App-side "share this Mac to the Fleet" controller. Runs a FleetAgentServer (Core) that
//             serves this Mac's MachineMetrics over TLS + mDNS, so another Mac's Fleet view discovers
//             and pairs with it like the Linux agent. Bridges the @MainActor monitor to the server's
//             background connection queue via a lock-guarded JSON cache refreshed every second.
//  Notes:     machineId is the IOPlatformUUID (stable per machine); hostname is the user-facing
//             computer name. The monitor's engine-derived peaks (anePeakWatts/mediaPeakGBs) and the
//             1-min load average — both outside SystemSnapshot — are injected into the mapping here.
//
import Foundation
import IOKit
import SiliconScopeCore

private let macAgentVersion = "1.0.0"

/// Thread-safe holder for the latest encoded MachineMetrics JSON: written on the main actor,
/// read on the server's connection queue.
final class MetricsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

@MainActor
final class MacAgentController {
    static let shared = MacAgentController()

    private var server: FleetAgentServer?
    private let cache = MetricsCache()
    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    var pairingToken: String? { server?.pairingToken }

    private weak var monitorRef: SiliconScopeMonitor?

    /// Remember the live monitor so Settings can toggle sharing on/off without threading it through.
    func configure(monitor: SiliconScopeMonitor) { monitorRef = monitor }
    func startIfConfigured() { if let m = monitorRef { start(monitor: m) } }

    func start(monitor: SiliconScopeMonitor, port: UInt16 = 7799) {
        guard !isRunning else { return }
        isRunning = true   // set up-front to prevent re-entry; reset on failure below
        let machineId = Self.platformUUID()
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osName = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let cache = self.cache
        let configDir = Self.configDir()

        // Refresh the served JSON once a second from the live monitor (on the main actor).
        task = Task { @MainActor in
            while !Task.isCancelled {
                let m = monitor.machineMetricsMac(machineId: machineId, hostname: hostname,
                                                  osName: osName, agentVersion: macAgentVersion)
                if let d = try? JSONEncoder().encode(m) { cache.set(d) }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // Build + start the server OFF the main actor: SecPKCS12Import blocks on a secd XPC round
        // trip, which deadlocks if run synchronously on the main actor.
        Task.detached { [weak self] in
            do {
                let s = try FleetAgentServer(port: port, configDir: configDir,
                                             metricsProvider: { cache.get() })
                try s.start()
                NSLog("[MacAgent] sharing this Mac on :\(port) (mDNS)")
                await MainActor.run { self?.server = s }
            } catch {
                NSLog("[MacAgent] start failed: \(error)")
                await MainActor.run { self?.isRunning = false; self?.task?.cancel(); self?.task = nil }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        server?.stop(); server = nil
        isRunning = false
    }

    private static func configDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SiliconScope/agent", isDirectory: true)
    }

    /// Stable per-machine identifier (survives renames), like the Linux agent's /etc/machine-id.
    private static func platformUUID() -> String {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if svc != 0 { IOObjectRelease(svc) } }
        if svc != 0,
           let uuid = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString,
                                                       kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? String {
            return uuid
        }
        return ProcessInfo.processInfo.hostName
    }
}

extension SiliconScopeMonitor {
    /// Map the current live snapshot into the fleet wire schema, injecting the values that live
    /// outside SystemSnapshot (engine peaks + 1-min load average).
    func machineMetricsMac(machineId: String, hostname: String, osName: String,
                           agentVersion: String) -> MachineMetrics {
        MachineMetrics.mac(
            snapshot: snapshot, topology: topology,
            hostname: hostname, machineId: machineId, osName: osName,
            agentVersion: agentVersion, tsMillis: Int64(Date().timeIntervalSince1970 * 1000),
            loadAvg1: Self.loadAvg1(), anePeakWatts: anePeakWatts, mediaPeakGBs: mediaPeakGBs,
            bandwidthPeakGBs: bandwidthPeakGBs
        )
    }

    private static func loadAvg1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}
