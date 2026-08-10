//
//  File:      TokenRateWatcher.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Collects the decode rate (tokens/sec) a local LLM runtime reports for its OWN work,
//             so a Mac serving models can publish it the way the Linux agent already does
//             (agent/tokenrate.go). Same two sources, same wire shape — a fleet must not describe
//             a Mac and a Linux box in different vocabularies.
//  Notes:     - llama.cpp server: `llamacpp:predicted_tokens_seconds` on /metrics (needs --metrics).
//               A plain HTTP poll, current by construction.
//             - LM Studio: no HTTP rate at all; `lms log stream --json --stats` emits a `stats`
//               object per FINISHED prediction. Push, so it needs a long-lived child process and
//               the value is "last known" rather than live — hence `measuredAt` on the wire.
//             ⚠️ Ollama publishes no server-side rate (its embedded llama-server is built without
//             `--metrics`), so it is absent here by fact rather than by oversight.
//             UI-free: this is Core, so it may not import SwiftUI. Thread-safe via a lock — the
//             sampler reads it from its own queue while the stream writes from another.
//
import Foundation

/// Watches whatever local runtime is willing to report its decode rate.
///
/// Start once and keep it for the process's lifetime; `latest()` is safe to call from any thread.
public final class TokenRateWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var lmStudio: FleetTokenRate?
    private var started = false

    /// Ports a llama.cpp-compatible server conventionally listens on (8080 is llama-server's default).
    private let llamaCppPorts: [Int]

    public init(llamaCppPorts: [Int] = [8080, 8081]) {
        self.llamaCppPorts = llamaCppPorts
    }

    /// Begins watching LM Studio. No-op when its CLI is absent — a machine without LM Studio simply
    /// has no stream to read, which is not an error worth surfacing.
    public func start() {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already, let bin = Self.lmsBinary() else { return }

        Thread.detachNewThread { [weak self] in
            while self != nil {
                self?.runLMStudioStream(bin)
                Thread.sleep(forTimeInterval: 15)   // LM Studio not running, or it quit — retry quietly
            }
        }
    }

    /// The rate to publish now: the live HTTP gauge when a llama.cpp server answers, otherwise the
    /// last prediction LM Studio reported. Preferring HTTP is deliberate — that number describes the
    /// present, while the stream's may be hours old.
    public func latest() -> FleetTokenRate? {
        if let r = readLlamaCppRate() { return r }
        lock.lock(); defer { lock.unlock() }
        return lmStudio
    }

    // MARK: - llama.cpp

    private func readLlamaCppRate() -> FleetTokenRate? {
        for port in llamaCppPorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/metrics"),
                  let text = Self.getSync(url, timeout: 1.5),
                  let v = Self.parsePrometheus(text, key: "llamacpp:predicted_tokens_seconds")
            else { continue }
            return FleetTokenRate(tokensPerSec: v, source: "llama.cpp", model: nil,
                                  measuredAt: Int64(Date().timeIntervalSince1970 * 1000), ttftSec: nil)
        }
        return nil
    }

    /// Pulls one gauge out of a Prometheus text exposition. `# HELP` / `# TYPE` lines repeat the key
    /// and must not be read as samples.
    static func parsePrometheus(_ text: String, key: String) -> Double? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix(key) else { continue }
            if let last = line.split(separator: " ").last, let v = Double(last) { return v }
        }
        return nil
    }

    /// Blocking GET. The agent samples on its own background queue, and a 1.5 s ceiling keeps a
    /// wedged runtime from stalling the sample loop.
    private static func getSync(_ url: URL, timeout: TimeInterval) -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data else { return }
            out = String(data: data, encoding: .utf8)
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return out
    }

    // MARK: - LM Studio

    /// LM Studio's CLI is not on PATH by default — its installer drops it in ~/.lmstudio/bin — so
    /// look in both rather than requiring the user to have fixed their shell.
    static func lmsBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.lmstudio/bin/lms", "/usr/local/bin/lms", "/opt/homebrew/bin/lms"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private func runLMStudioStream(_ bin: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["log", "stream", "--json", "--stats"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return }
        defer { if proc.isRunning { proc.terminate() } }

        // Read line-wise: one prediction event carries its whole output, so lines are long but the
        // stream is slow — a simple accumulating read is enough and avoids a byte-at-a-time loop.
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }              // stream closed → LM Studio quit
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                ingest(line)
            }
            if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }   // a wedged line must not grow forever
        }
        proc.waitUntilExit()
    }

    private func ingest(_ line: Data) {
        guard let first = line.first, first == 0x7B,          // '{' — the stream opens with a banner
              let ev = try? JSONDecoder().decode(LMStudioEvent.self, from: line),
              let stats = ev.data.stats, stats.tokensPerSecond > 0   // a cancelled prediction reports 0
        else { return }
        let at = ev.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        let rate = FleetTokenRate(tokensPerSec: stats.tokensPerSecond, source: "lmstudio",
                                  model: ev.data.modelIdentifier, measuredAt: at,
                                  ttftSec: stats.timeToFirstTokenSec)
        lock.lock(); lmStudio = rate; lock.unlock()
    }

    private struct LMStudioEvent: Decodable {
        struct Payload: Decodable {
            struct Stats: Decodable {
                let tokensPerSecond: Double
                let timeToFirstTokenSec: Double?
            }
            let modelIdentifier: String?
            let stats: Stats?
        }
        let timestamp: Int64?
        let data: Payload
    }
}
