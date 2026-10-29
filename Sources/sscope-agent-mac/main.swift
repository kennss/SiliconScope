//
//  File:      main.swift
//  Created:   2026-07-22
//  Updated:   2026-10-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Headless SiliconScope fleet agent for a Mac (launchd / CLI). Samples this Mac's live
//             metrics via Core's SystemSampler once a second, maps them to MachineMetrics, and serves
//             them over TLS + token + mDNS through FleetAgentServer — the same data + transport as
//             the app's "Share this Mac" mode, but with no GUI (for headless Mac minis / Studios).
//  Notes:     Mirrors Sources/SiliconScope/MacAgent.swift; the only difference is the snapshot comes
//             from `SystemSampler().sample()` in a background loop instead of the @MainActor monitor.
//             Sampling blocks ~interval, and FleetAgentServer's SecPKCS12Import blocks on a secd XPC
//             round trip, so both run off the main thread. Flags: --version, --print-token,
//             --pair-url (one-line pairing handoff for the viewer), --once (print one sample as
//             JSON and exit — the diagnostic for a machine we can't sit at, e.g. Intel in #69),
//             --serve :PORT (default 7799). A running AI runtime's local API is asked what it has
//             loaded (localhost only, only while one is observed), so remote pages show the model.
//
import Foundation
import IOKit
import SiliconScopeCore

// 1.2.0: thermal state, DVFS ceilings, disk + network throughput, AI runtimes and loaded model,
// processes, battery, and the power basis for macOS 27 (#56, #65). A viewer shows a reduced remote
// page for anything older, so this is the number to look for when a remote page looks thin.
// 1.3.0: fans on every architecture as their own field, Intel temperatures (sp78), and "fanless"
// only when the SMC says so (#69); `--once` for diagnosis.
// 1.4.0: keeps the viewer's connection open between polls and gzips /metrics (#71).
// 1.4.1: network totals leave out VPN tunnels, which counted the same bytes twice (#74).
private let agentVersion = "1.4.2"
private let defaultPort: UInt16 = 7799

/// What the local AI runtime's API last said, and which runtimes the sample loop last saw — shared
/// between that loop and the probe task (#56). The same rules as the app's monitor: ask only a
/// runtime that is running, every `cadence` seconds, and treat an answer older than three cadences
/// as unreachable rather than as current.
final class RuntimeAPIState: @unchecked Sendable {
    static let cadence: TimeInterval = 2.5
    private let lock = NSLock()
    private var answer = RuntimeAPISample()
    private var seen = AIRuntimeSample()

    func publish(_ s: RuntimeAPISample) { lock.lock(); answer = s; lock.unlock() }
    func observe(_ r: AIRuntimeSample) { lock.lock(); seen = r; lock.unlock() }
    func runtimes() -> AIRuntimeSample { lock.lock(); defer { lock.unlock() }; return seen }

    func latest() -> RuntimeAPISample {
        lock.lock(); var s = answer; lock.unlock()
        if s.status == .ok, let updated = s.lastUpdated,
           Date().timeIntervalSince(updated) > 3 * Self.cadence {
            s.status = .unreachable
        }
        return s
    }
}

/// Thread-safe holder for the latest encoded MachineMetrics JSON (written by the sample loop, read
/// on the server's connection queue).
final class MetricsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

func agentConfigDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("SiliconScope/agent", isDirectory: true)
}

/// Stable per-machine id (survives renames), like the Linux agent's /etc/machine-id.
func platformUUID() -> String {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { if svc != 0 { IOObjectRelease(svc) } }
    if svc != 0,
       let uuid = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
           .takeRetainedValue() as? String {
        return uuid
    }
    return ProcessInfo.processInfo.hostName
}

func loadAvg1() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
}

func logErr(_ s: String) { FileHandle.standardError.write(Data("sscope-agent-mac: \(s)\n".utf8)) }

/// The persisted pairing token, creating it on first call (same file the server uses).
func readOrCreateToken() -> String {
    let tokenPath = agentConfigDir().appendingPathComponent("token")
    if let t = try? String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !t.isEmpty {
        return t
    }
    if let server = try? FleetAgentServer(port: defaultPort, configDir: agentConfigDir(),
                                          metricsProvider: { Data() }) {
        return server.pairingToken   // creates + persists the token on first run
    }
    return ""
}

/// This machine's primary non-loopback IPv4, so the pairing link names an address the viewer can
/// actually reach. Falls back to the hostname (resolvable via mDNS on the same LAN).
func primaryIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var best: String?
    for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ifa.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ifa.pointee.ifa_addr, socklen_t(ifa.pointee.ifa_addr.pointee.sa_len),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        let name = String(cString: ifa.pointee.ifa_name)
        if ip.hasPrefix("169.254.") { continue }         // link-local autoconf — not routable
        if name.hasPrefix("en") { return ip }            // prefer Ethernet/Wi-Fi
        if best == nil { best = ip }                     // else first usable (utun/tailscale/bridge)
    }
    return best
}

// MARK: - CLI flags

let args = CommandLine.arguments
// A `let`, so the server's background queue can read it: a mutable top-level global is main-actor
// state, and Swift 6.1 refuses to read it off the main actor (#69).
let port: UInt16 = {
    guard let i = args.firstIndex(of: "--serve"), i + 1 < args.count else { return defaultPort }
    let raw = args[i + 1].hasPrefix(":") ? String(args[i + 1].dropFirst()) : args[i + 1]
    return UInt16(raw) ?? defaultPort
}()

if args.contains("--version") { print(agentVersion); exit(0) }
if args.contains("--print-token") { print(readOrCreateToken()); exit(0) }
// One-line pairing handoff: everything the viewer needs (name + address + port + token) in a single
// string to paste into "Add machine…", instead of hand-carrying a bare token. Percent-encoded here
// because a Mac's computer name routinely contains spaces and non-ASCII.
if args.contains("--pair-url") {
    let link = PairingLink(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                           host: primaryIPv4() ?? ProcessInfo.processInfo.hostName,
                           port: Int(port),
                           token: readOrCreateToken())
    print(link.url)
    exit(0)
}

// MARK: - sample loop + server

let cache = MetricsCache()
let machineId = platformUUID()
let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
let osv = ProcessInfo.processInfo.operatingSystemVersion
let osName = "macOS \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"

// Publishes tok/s when a local runtime reports one (LM Studio's stream / llama.cpp's /metrics).
// Created idle: it attaches only while an LM Studio process is observed. Starting it eagerly
// spawned `lms log stream`, and that LAUNCHES LM Studio — a headless agent must report what the
// machine is doing, never add to it (#60).
let tokenRate = TokenRateWatcher()

/// The sampler and the engine that tracks peaks across samples, and the one place a payload is
/// built, so `--once` prints exactly what the server sends.
///
/// Confined, not locked: after `--once` (main thread, before any queue starts) only the sample
/// queue touches it. That confinement is what `@unchecked Sendable` asserts. MetricsEngine is not
/// Sendable, so as a bare top-level global it was main-actor state read from that queue, which
/// Swift 6.2 lets through and 6.1 rejects (#69).
final class SampleLoop: @unchecked Sendable {
    let sampler = SystemSampler()
    private let topology: CPUTopology?
    private let engine: MetricsEngine

    init() {
        topology = sampler.topology
        engine = MetricsEngine(topology: topology)
    }

    func sample() -> SystemSnapshot { sampler.sample(interval: 0.2) }

    func ingest(_ snap: SystemSnapshot, dt: Double) { engine.ingest(snap, dt: dt) }

    func payload(_ snap: SystemSnapshot, now: Date, rate: FleetTokenRate?) -> MachineMetrics {
        MachineMetrics.mac(
            snapshot: snap, topology: topology, hostname: hostname, machineId: machineId,
            osName: osName, agentVersion: agentVersion,
            tsMillis: Int64(now.timeIntervalSince1970 * 1000), loadAvg1: loadAvg1(),
            anePeakWatts: engine.anePeakWatts, mediaPeakGBs: engine.mediaPeakGBs,
            bandwidthPeakGBs: engine.bandwidthPeakGBs,
            gpuClockPeakMHz: engine.gpuClockPeakMHz,
            tokenRate: rate
        )
    }
}
let loop = SampleLoop()

// One sample to stdout, then exit: what a user pastes into an issue from a machine we don't have.
// CPU usage is a delta against the previous call, so the first sample is taken and discarded.
if args.contains("--once") {
    _ = loop.sample()
    Thread.sleep(forTimeInterval: 1)
    let snap = loop.sample()
    loop.ingest(snap, dt: 1)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(loop.payload(snap, now: Date(), rate: nil)) {
        FileHandle.standardOutput.write(data)
        print()
    }
    exit(0)
}

// What the running runtime has loaded, so a remote page shows the model the way This Mac does (#56).
// Only a runtime the process scan has SEEN is asked, and only over localhost — no runtime, no
// request. Ports are the runtimes' defaults: the app's per-runtime port settings have no headless
// equivalent, and a runtime on another port reads as "no server", which is what it is to us.
let runtimeAPI = RuntimeAPIState()
Task.detached {
    let client = RuntimeAPIClient()
    while true {
        let seen = runtimeAPI.runtimes()
        if let kind = seen.primaryKind, kind.servesAPI {
            runtimeAPI.publish(await client.probe(kind: kind, port: seen.apiPort(for: kind)))
        } else {
            runtimeAPI.publish(RuntimeAPISample())          // nothing asked → nothing reported
        }
        try? await Task.sleep(for: .seconds(RuntimeAPIState.cadence))
    }
}

// Sampling blocks ~interval; run it on a dedicated background queue.
let sampleQueue = DispatchQueue(label: "ai.calidalab.sscope-agent.sample")
sampleQueue.async {
    var lastTick = Date()
    while true {
        var snap = loop.sample()
        runtimeAPI.observe(snap.aiRuntime)
        snap.runtimeAPI = runtimeAPI.latest()
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        loop.ingest(snap, dt: dt)
        let payload = loop.payload(snap, now: now,
                                   rate: tokenRate.latest(llamaCppPort: snap.aiRuntime.llamaCppPort,
                                                          lmStudioRunning: snap.aiRuntime.isLMStudioRunning))
        if let d = try? JSONEncoder().encode(payload) { cache.set(d) }
        Thread.sleep(forTimeInterval: 0.8)   // total cadence ≈ 1 s
    }
}

// Start the server off the main thread (SecPKCS12Import blocks on a secd XPC round trip).
nonisolated(unsafe) var serverHolder: FleetAgentServer?
DispatchQueue.global(qos: .utility).async {
    do {
        let server = try FleetAgentServer(port: port, configDir: agentConfigDir(),
                                          metricsProvider: { cache.get() })
        try server.start()
        serverHolder = server
        logErr("serving on :\(port) (mDNS) — enter this token in another Mac's SiliconScope:")
        logErr(server.pairingToken)
    } catch {
        logErr("start failed: \(error)")
        exit(1)
    }
}

dispatchMain()
