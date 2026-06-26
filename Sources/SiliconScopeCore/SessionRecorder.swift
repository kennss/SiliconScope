//
//  File:      SessionRecorder.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Records a session of SystemSnapshots to a JSONL file (one snapshot per line) for
//             later trend analysis and Phase-2 replay. Streams to a temp file as it records
//             (crash-safe, unbounded length); exports either the lossless .ssrec (JSONL) or a
//             flattened CSV of the key metrics. Phase 1 of the record/replay feature (#data-export).
//  Notes:     1 Hz by default (append() self-gates on `cadence`). Processes are trimmed to the top
//             N per frame (matches the dashboard's visible list) to bound size. NOT thread-safe —
//             drive it from one context (the monitor loop). Unavailable metrics export as blank
//             CSV cells. The .ssrec first line is a "meta" object; the rest are Frame objects.
//
import Foundation

public final class SessionRecorder {
    public private(set) var isRecording = false
    public private(set) var sampleCount = 0
    public private(set) var startedAt: Date?
    public private(set) var fileURL: URL?      // temp .ssrec currently being written

    private let cadence: TimeInterval
    private let maxProcesses: Int
    private var lastWriteAt: Date?
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init(cadence: TimeInterval = 1.0, maxProcesses: Int = 30) {
        self.cadence = cadence
        self.maxProcesses = maxProcesses
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// Seconds since recording started (0 when idle).
    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Begins a recording: creates a temp .ssrec, writes the meta line, starts the clock.
    public func start(directory: URL? = nil, topology: CPUTopology? = nil) throws {
        guard !isRecording else { return }
        let dir = directory ?? FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("SiliconScope-recording-\(stamp).ssrec")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        let meta = RecordingMeta(version: recordingFormatVersion, app: Self.appVersion,
                                 chip: Self.sysctl("machdep.cpu.brand_string"),
                                 model: Self.sysctl("hw.model"),
                                 os: ProcessInfo.processInfo.operatingSystemVersionString,
                                 started: Date(), cadenceHz: cadence > 0 ? 1.0 / cadence : 0,
                                 topology: topology)
        try writeLine(h, encoder.encode(meta))
        handle = h; fileURL = url
        startedAt = Date(); lastWriteAt = nil; sampleCount = 0; isRecording = true
    }

    /// Appends a frame if at least `cadence` seconds have passed since the last (the 1 Hz gate).
    public func append(_ snapshot: SystemSnapshot) {
        guard isRecording, let started = startedAt, let h = handle else { return }
        let now = Date()
        if let last = lastWriteAt, now.timeIntervalSince(last) < cadence { return }
        lastWriteAt = now
        var snap = snapshot
        if snap.processes.count > maxProcesses {
            snap.processes = Array(snap.processes.prefix(maxProcesses))   // dashboard shows a sorted list
        }
        guard let data = try? encoder.encode(RecordedFrame(t: now.timeIntervalSince(started), snapshot: snap)) else { return }
        try? writeLine(h, data)
        sampleCount += 1
    }

    /// Stops recording and closes the file (the temp .ssrec remains, ready to export).
    public func stop() {
        guard isRecording else { return }
        try? handle?.synchronize(); try? handle?.close()
        handle = nil; isRecording = false
    }

    public enum ExportError: Error { case noRecording }

    /// Copies the lossless JSONL recording to `dest` (.ssrec).
    public func exportRecording(to dest: URL) throws {
        guard let src = fileURL else { throw ExportError.noRecording }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    /// Writes a flattened CSV of the key metrics to `dest`.
    public func exportCSV(to dest: URL) throws {
        guard let src = fileURL else { throw ExportError.noRecording }
        try Self.csv(fromRecordingAt: src).write(to: dest, atomically: true, encoding: .utf8)
    }

    // MARK: - CSV (pure, testable)

    public static let csvColumns = [
        "timestamp_iso", "elapsed_s",
        "cpu_e_pct", "cpu_p_pct", "cpu_e_mhz", "cpu_p_mhz",
        "gpu_pct", "gpu_mhz", "gpu_mem_gb",
        "cpu_w", "ecpu_w", "pcpu_w", "gpu_w", "ane_w", "dram_w", "soc_w",
        "bw_cpu", "bw_gpu", "bw_media", "bw_other", "bw_total",
        "mem_used_gb", "mem_total_gb", "mem_pressure", "swap_used_gb",
        "temp_cpu_avg", "temp_cpu_max", "temp_gpu", "temp_batt",
        "thermal_pressure", "thermal_throttling", "fan_rpm",
        "batt_pct", "batt_state",
        "ai_runtime", "ai_model", "ai_engine",
    ]
    public static var csvHeader: String { csvColumns.joined(separator: ",") }

    /// Reads a JSONL recording file and renders it as CSV (header + one row per frame).
    public static func csv(fromRecordingAt url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var started = Date()
        var rows: [String] = [csvHeader]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let meta = try? dec.decode(RecordingMeta.self, from: data), meta.kind == "meta" {
                started = meta.started; continue
            }
            if let frame = try? dec.decode(RecordedFrame.self, from: data) {
                rows.append(csvRow(frame.snapshot, t: frame.t, started: started))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// One CSV row for a snapshot. Metrics the chip doesn't expose render as blank cells.
    public static func csvRow(_ s: SystemSnapshot, t: Double, started: Date) -> String {
        func n(_ v: Double, _ p: Int = 2) -> String { String(format: "%.\(p)f", v) }
        func q(_ str: String) -> String {        // CSV-escape a free-text field
            (str.contains(",") || str.contains("\"") || str.contains("\n"))
                ? "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : str
        }
        let fields: [String] = [
            ISO8601DateFormatter().string(from: started.addingTimeInterval(t)), n(t),
            n(s.cpu.eUsagePercent, 1), n(s.cpu.pUsagePercent, 1), n(s.cpu.eFreqMHz, 0), n(s.cpu.pFreqMHz, 0),
            n(s.gpu.usagePercent, 1), n(s.gpu.freqMHz, 0), n(s.gpu.inUseMemoryGB),
            n(s.power.cpuWatts), n(s.power.eCPUWatts), n(s.power.pCPUWatts), n(s.power.gpuWatts),
            n(s.power.aneWatts), n(s.power.dramWatts), n(s.power.socWatts),
            n(s.bandwidth.cpuGBs), n(s.bandwidth.gpuGBs), n(s.bandwidth.mediaGBs),
            n(s.bandwidth.otherGBs), n(s.bandwidth.totalGBs),
            n(s.memory.usedGB), n(s.memory.totalGB), s.memory.pressure.rawValue, n(s.memory.swapUsedGB),
            s.temperature.hasCPU ? n(s.temperature.cpuCelsius, 1) : "",
            s.temperature.hasCPU ? n(s.temperature.cpuMaxCelsius, 1) : "",
            s.temperature.hasGPU ? n(s.temperature.gpuCelsius, 1) : "",
            s.temperature.hasBattery ? n(s.temperature.batteryCelsius, 1) : "",
            s.thermal.pressure.rawValue, s.thermal.isThrottling ? "1" : "0",
            s.thermal.hasFans ? n(s.thermal.maxFanRPM, 0) : "",
            s.battery.hasBattery ? n(s.battery.percent, 0) : "",
            q(s.battery.stateLabel),
            q(s.aiRuntime.primaryKind?.displayName ?? ""),
            q(s.runtimeAPI.primaryModel?.name ?? ""),
            q(s.likelyAIEngine),
        ]
        return fields.joined(separator: ",")
    }

    // MARK: - Private

    private func writeLine(_ h: FileHandle, _ data: Data) throws {
        try h.write(contentsOf: data)
        try h.write(contentsOf: Data([0x0A]))
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    private static func sysctl(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }
}
