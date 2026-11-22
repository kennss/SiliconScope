//
//  File:      ChipReport.swift
//  Created:   2026-11-20
//  Updated:   2026-11-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  `sscope-cli --chip-report`: one command that measures a Mac the way a sensor, power or
//             bandwidth contribution needs it measured, and packs the result into one zip on the
//             Desktop. Idle, then E-cores only, every core, the GPU only, and a memory-streaming GPU
//             kernel, each held for a minute with a cool-down between; at each phase the CLI's own
//             dumps (--sensors-all, --sensors, --bandwidth) are captured, and a summary sets out
//             each SMC key's rise per load and the bandwidth read against the bandwidth the GPU
//             timed itself moving.
//  Notes:     The procedure is the one @SpencerCurtis built by hand for the M3 Ultra (#93) — his
//             load scripts, cool-downs and per-key comparison — implemented here from scratch so
//             the next contributor runs it with one command and every report has the same shape.
//             Loads run only when the user runs this command and confirms it; the app never loads
//             the machine (CONTRIBUTING rule 4). Nothing is uploaded: the zip stays on the Desktop.
//             The captures pass --no-processes, so no process names, and the report holds no host
//             name, IP address or serial number.
//             Captures re-run this executable rather than duplicating its dumps, so a report reads
//             exactly like the outputs contributors already paste.
//
import Foundation
import Metal
import os
import SiliconScopeCore

enum ChipReport {
    static let loadSeconds: UInt64 = 60
    static let coolSeconds: UInt64 = 90

    static func run(arguments: [String]) async -> Int32 {
        let topology = CPUSampler()?.topology
        let eCores = topology?.eCoreCount ?? 0
        let allCores = ProcessInfo.processInfo.activeProcessorCount
        let phases = eCores > 0 ? 5 : 4
        // Every phase, idle included, starts after a cool-down; each load runs a minute.
        let minutes = Int((Double(phases) * Double(coolSeconds) + Double(phases - 1) * Double(loadSeconds) + 60) / 60)

        print("""
        sscope chip report — measures this Mac under standard loads and saves one zip.

          idle → E-cores only → every core → GPU only → GPU memory streaming
          about \(minutes) minutes; the fans will spin up. Close busy apps first.
          Nothing is uploaded. The zip has no host name, IP address, serial number or process list.
        """)
        if !arguments.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else {
                FileHandle.standardError.write(Data("Not a terminal: pass --yes to run without asking.\n".utf8))
                return 2
            }
            print("Continue? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("Cancelled.")
                return 1
            }
        }

        guard let exe = Bundle.main.executableURL else {
            FileHandle.standardError.write(Data("Can't locate sscope-cli itself.\n".utf8))
            return 1
        }
        let stamp = Self.stamp()
        let name = "sscope-chip-report-\(Self.sysctlString("hw.model") ?? "mac")-\(stamp)"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let folder = desktop.appendingPathComponent(name)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            FileHandle.standardError.write(Data("Can't create \(folder.path): \(error)\n".utf8))
            return 1
        }

        let started = Date()
        let usage = UsageProbe(topology: topology)
        let temperature = TemperatureSampler()
        func smcReadings() -> [String: Double] {
            Dictionary(temperature.allSMCKeys().compactMap { e in e.celsius.map { (e.key, $0) } },
                       uniquingKeysWith: { a, _ in a })
        }
        var usageLines: [String] = []
        func capture(_ phase: String, _ extra: [String] = []) {
            Self.log(started, "capturing \(phase)…")
            Self.runSelf(exe, ["--no-processes", "--sensors-all", "--sensors", "--bandwidth"] + extra,
                         to: folder.appendingPathComponent("\(phase).txt"))
        }

        // 1. Idle — after the same cool-down every load gets, so idle is the baseline the loads
        //    are measured from rather than whatever the machine was doing a minute ago. (Run right
        //    after another report, idle read 10 °C warm and the E-core phase showed a 7 °C "fall".)
        await Self.cool(started)
        Self.log(started, "idle")
        usageLines.append(usage.line("idle"))
        let idle = smcReadings()
        capture("idle", ["--cpu-debug", "--power-debug"])

        var loads: [(label: String, readings: [String: Double])] = []

        // 2. E-cores only: background QoS keeps the threads off the P-cores, as `taskpolicy -b` did.
        if eCores > 0 {
            Self.log(started, "E-cores only — \(eCores) background threads for \(loadSeconds) s")
            let load = CPULoad(threads: eCores, qos: .background)
            try? await Task.sleep(for: .seconds(loadSeconds))
            usageLines.append(usage.line("ecore"))
            loads.append(("ecore", smcReadings()))
            capture("ecore")
            load.stop()
            await Self.cool(started)
        }

        // 3. Every core.
        Self.log(started, "every core — \(allCores) threads for \(loadSeconds) s")
        let cpuLoad = CPULoad(threads: allCores, qos: .userInitiated)
        try? await Task.sleep(for: .seconds(loadSeconds))
        usageLines.append(usage.line("allcpu"))
        loads.append(("allcpu", smcReadings()))
        capture("allcpu")
        cpuLoad.stop()
        await Self.cool(started)

        // 4. GPU only: an arithmetic kernel, so the heat is the GPU's and not the memory's.
        Self.log(started, "GPU only — compute kernel for \(loadSeconds) s")
        let gpuLoad = GPULoad(kind: .compute)
        gpuLoad?.start()
        try? await Task.sleep(for: .seconds(loadSeconds))
        usageLines.append(usage.line("gpu"))
        loads.append(("gpu", smcReadings()))
        capture("gpu")
        gpuLoad?.stop()
        if gpuLoad == nil { Self.log(started, "no Metal device — GPU phases skipped") }
        await Self.cool(started)

        // 5. Memory streaming: the GPU times the bytes it moves; SiliconScope reads the bandwidth.
        Self.log(started, "GPU memory streaming — \(loadSeconds) s")
        let stream = GPULoad(kind: .stream)
        stream?.start()
        try? await Task.sleep(for: .seconds(loadSeconds - 10))
        var readings: [BandwidthSample] = []
        if let bw = BandwidthSampler() {
            for _ in 0..<5 { readings.append(bw.sample(interval: 1.0)) }
        }
        usageLines.append(usage.line("stream"))
        capture("stream")
        stream?.stop()
        let kernelGBs = stream?.measuredGBs

        // Summary + system + README, then the zip.
        let curated = Set(SensorCatalog.curated(for: SensorCatalog.detectGeneration()).map(\.key))
        let rises = ChipReportAnalysis.sensorRises(idle: idle, loads: loads, curated: curated)
        let system = Self.systemInfo(topology: topology)
        let summary = """
        \(system)

        === load seen by SiliconScope (E-cores, P-cores, GPU busy) ===
        \(usageLines.joined(separator: "\n"))

        === SMC temperature keys: rise over idle (°C) ===
        * = present on this chip but not in the curated table. — = not read in that phase.
        \(ChipReportAnalysis.sensorTable(rises, loadLabels: loads.map(\.label)))

        === memory bandwidth cross-check ===
        \(ChipReportAnalysis.bandwidthCheck(kernelGBs: kernelGBs, readings: readings))
        """
        Self.write(summary, to: folder.appendingPathComponent("summary.txt"))
        Self.write(system, to: folder.appendingPathComponent("system.txt"))
        Self.write(Self.readme(phases: loads.map(\.label)), to: folder.appendingPathComponent("README.txt"))

        let zip = desktop.appendingPathComponent(name + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Without these, ditto adds a "._" AppleDouble file per report file carrying its
        // extended attributes (com.apple.provenance, TextEncoding): clutter, not data (#95).
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                           "--keepParent", folder.path, zip.path]
        try? ditto.run(); ditto.waitUntilExit()

        Self.log(started, "done")
        print("""

        Saved:
          \(zip.path)
          \(folder.path)   (the same files, unzipped)

        Attach the zip to an issue: https://github.com/kennss/SiliconScope/issues/new
        It holds: summary.txt (start here), system.txt, one capture per phase, README.txt.
        """)
        return 0
    }

    // MARK: - Steps

    private static func cool(_ started: Date) async {
        log(started, "cooling down \(coolSeconds) s")
        try? await Task.sleep(for: .seconds(coolSeconds))
    }

    /// Runs this executable with `args`, stdout and stderr into `url`.
    private static func runSelf(_ exe: URL, _ args: [String], to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: url) else { return }
        defer { try? out.close() }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        do { try p.run(); p.waitUntilExit() } catch {
            out.write(Data("could not run sscope-cli: \(error)\n".utf8))
        }
    }

    private static func log(_ started: Date, _ text: String) {
        let s = Int(Date().timeIntervalSince(started))
        print(String(format: "[%02d:%02d] ", s / 60, s % 60) + text)
    }

    private static func write(_ text: String, to url: URL) {
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    // MARK: - System facts (no host name, no serial)

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
    }

    private static func systemInfo(topology: CPUTopology?) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        var lines = [
            "=== system ===",
            "SiliconScope: \(version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "hw.model: \(sysctlString("hw.model") ?? "—")",
            "machdep.cpu.brand_string: \(sysctlString("machdep.cpu.brand_string") ?? "—")",
            "hw.memsize: " + (sysctlInt("hw.memsize").map { String(format: "%.0f GB", Double($0) / 1_073_741_824) } ?? "—"),
        ]
        let levels = Int(sysctlInt("hw.nperflevels") ?? 0)
        for i in 0..<levels {
            let n = sysctlString("hw.perflevel\(i).name") ?? "?"
            let c = sysctlInt("hw.perflevel\(i).physicalcpu").map(String.init) ?? "?"
            lines.append("hw.perflevel\(i): \(n) × \(c)")
        }
        if let t = topology { lines.append("SiliconScope topology: \(t.coreSummary)") }
        lines.append("SMC generation: \(SensorCatalog.detectGeneration())")
        lines.append("report generated: \(ISO8601DateFormatter().string(from: Date()))")
        return lines.joined(separator: "\n")
    }

    private static func readme(phases: [String]) -> String {
        """
        SiliconScope chip report

        Made by `sscope-cli --chip-report`. The procedure follows the one @SpencerCurtis built for the
        M3 Ultra (github.com/kennss/SiliconScope/issues/93).

        summary.txt   start here: load seen per phase, each SMC key's rise over idle, and the
                      bandwidth SiliconScope read against what a GPU kernel timed itself moving
        system.txt    macOS, model, chip, memory, core clusters, SiliconScope version
        idle.txt      at rest: --sensors-all, --sensors, --bandwidth, --cpu-debug, --power-debug
        \(phases.map { "\($0).txt" }.joined(separator: " "))
                      the same dumps (--sensors-all, --sensors, --bandwidth) under each load
        stream.txt    the dumps while the GPU streamed memory

        No host name, IP address, serial number or process list is included. Nothing was uploaded.
        """
    }
}

// MARK: - Loads

/// Busy threads doing dependent floating-point arithmetic until stopped.
final class CPULoad: Sendable {
    private let running = OSAllocatedUnfairLock(initialState: true)

    init(threads: Int, qos: QualityOfService) {
        for i in 0..<max(1, threads) {
            let thread = Thread { [self] in self.burn(seed: Double(i)) }
            thread.qualityOfService = qos
            thread.start()
        }
    }

    func stop() { running.withLock { $0 = false } }

    private func burn(seed: Double) {
        var a = seed + 1.0001, b = 0.9999
        let c = 1e-9
        while running.withLock({ $0 }) {
            for _ in 0..<2_000_000 { a = a.addingProduct(b, c); b = b.addingProduct(c, a) * 0.5 + 0.5 }
        }
        // Used, so the loop cannot be optimised away.
        if a == .infinity { print(a + b) }
    }
}

/// A Metal kernel kept running on its own thread until stopped. `.compute` is arithmetic-bound
/// (heat in the GPU); `.stream` copies a large buffer and accumulates GPU-timed bytes per second.
final class GPULoad: @unchecked Sendable {
    enum Kind { case compute, stream }

    private let kind: Kind
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffers: [MTLBuffer]
    private let threads: Int
    private let bytesPerPass: Double
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let moved = OSAllocatedUnfairLock(initialState: (bytes: 0.0, seconds: 0.0))

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float a = float(id) * 1e-6f, b = 1.0001f, c = 0.9999f;
        for (int i = 0; i < 4096; i++) { a = fma(a, b, c); b = fma(b, c, a * 1e-9f); }
        out[id] = a + b;
    }
    kernel void stream(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                       uint id [[thread_position_in_grid]]) {
        dst[id] = src[id] * 1.0001f;
    }
    """

    init?(kind: Kind) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: kind == .compute ? "burn" : "stream"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.kind = kind
        self.queue = queue
        self.pipeline = pipeline
        switch kind {
        case .compute:
            let count = 1 << 22
            guard let out = device.makeBuffer(length: count * 4, options: .storageModePrivate) else { return nil }
            buffers = [out]; threads = count; bytesPerPass = 0
        case .stream:
            // Large enough to defeat the caches, small enough for an 8 GB Mac: 1/32 of RAM per
            // buffer, at most 512 MB.
            let size = min(512 << 20, Int(ProcessInfo.processInfo.physicalMemory / 32)) & ~0xFFFF
            guard let src = device.makeBuffer(length: size, options: .storageModePrivate),
                  let dst = device.makeBuffer(length: size, options: .storageModePrivate) else { return nil }
            buffers = [src, dst]; threads = size / 16; bytesPerPass = Double(size) * 2   // read + write
        }
    }

    func start() {
        Thread { [self] in self.loop() }.start()
    }

    func stop() { running.withLock { $0 = false } }

    /// Bytes moved per second of GPU time, read + write; nil for the compute kernel or before a pass.
    var measuredGBs: Double? {
        let m = moved.withLock { $0 }
        return m.seconds > 0 ? m.bytes / m.seconds / 1e9 : nil
    }

    private func loop() {
        let passes = 8
        while running.withLock({ $0 }) {
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(pipeline)
            for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: i) }
            let width = min(pipeline.maxTotalThreadsPerThreadgroup, 1024)
            for _ in 0..<passes {
                enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            if kind == .stream, cmd.gpuEndTime > cmd.gpuStartTime {
                let bytes = bytesPerPass * Double(passes), secs = cmd.gpuEndTime - cmd.gpuStartTime
                moved.withLock { $0.bytes += bytes; $0.seconds += secs }
            }
        }
    }
}

/// How busy SiliconScope sees the CPU clusters and the GPU — the check that each load landed
/// where it was meant to.
final class UsageProbe {
    private let cpu: CPUSampler?
    private let gpu: GPUSampler?

    init(topology: CPUTopology?) {
        cpu = CPUSampler()
        gpu = topology.flatMap { GPUSampler(topology: $0) }
    }

    /// Busy share over the next second. CPU usage is a tick delta since the sampler's previous
    /// call, so the first call only sets the baseline — measured once per phase, it averaged the
    /// cool-down before it into the load (an every-core load read P 44 %).
    func line(_ phase: String) -> String {
        _ = cpu?.sample(interval: 0.05)
        let g = gpu?.sample(interval: 1.0) ?? GPUSample()
        let c = cpu?.sample(interval: 0.05) ?? CPUSample()
        let label = phase.padding(toLength: 7, withPad: " ", startingAt: 0)
        return label + String(format: " E %3.0f%%  P %3.0f%%  GPU %3.0f%%",
                              c.eUsagePercent, c.pUsagePercent, g.usagePercent)
    }
}
