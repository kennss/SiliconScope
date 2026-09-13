//
//  File:      TokenRateWatcher.swift
//  Created:   2026-08-10
//  Updated:   2026-09-13
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Collects the decode rate (tokens/sec) a local LLM runtime reports for its OWN work,
//             so a Mac serving models can publish it the way the Linux agent already does
//             (agent/tokenrate.go). Same two sources, same wire shape — a fleet must not describe
//             a Mac and a Linux box in different vocabularies.
//  Notes:     - llama.cpp server: `llamacpp:predicted_tokens_seconds` on /metrics (needs --metrics).
//               A plain HTTP poll, current by construction — but ONLY against a port the caller
//               observed a llama.cpp process on. This type deliberately holds no port list (#53).
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
    /// The running `lms log stream` child, when one is attached. Held so the stream can be torn
    /// down the moment LM Studio is no longer observed.
    private var stream: Process?
    /// Last observation, so an attach can be edge-triggered rather than level-triggered.
    private var wasRunning = false

    public init() {}

    /// Attaches to, or detaches from, LM Studio's log stream to match what is ACTUALLY running.
    ///
    /// ⚠️ This must never be the thing that makes LM Studio run. `lms log stream` starts LM Studio
    /// in service mode when it is not already up, so the previous design — spawn it, and on failure
    /// retry every 15 s forever — meant SiliconScope launched LM Studio at login and relaunched it
    /// within 15 s of the user quitting it. Two processes did this independently (the app and the
    /// headless agent), so killing it could not win (#60). A monitor may not start what it monitors.
    ///
    /// `running` is an OBSERVATION the caller already made (`AIRuntimeSample`), not something this
    /// type goes looking for — the same rule the llama.cpp port follows since #53.
    /// Whether to attach the log stream, given the current observation, the previous one, and
    /// whether a stream is already up. Pure and extracted from the process-spawning path so the
    /// rule that stops #60 can be tested without launching anything.
    ///
    /// Attaching is edge-triggered: `running` alone is not enough, because the stream dies the
    /// moment LM Studio quits while the process scan behind `running` is up to a sample stale.
    /// A level test therefore sees "not attached, still running" in that gap and re-attaches —
    /// spawning `lms`, which starts LM Studio again. Only a false→true transition can attach.
    static func shouldAttach(running: Bool, wasRunning: Bool, attached: Bool) -> Bool {
        running && !wasRunning && !attached
    }

    /// Detaching is level-triggered on purpose: the moment LM Studio is not observed we let the
    /// stream go, however we got here.
    static func shouldDetach(running: Bool, attached: Bool) -> Bool { !running && attached }

    private func syncLMStudioStream(running: Bool) {
        lock.lock()
        let attached = stream != nil
        // ⚠️ Attach on the RISING EDGE of the observation, never on its level. The stream dies the
        // instant LM Studio quits, but the process scan behind `running` is up to a sample old — so
        // a level test sees "not attached, still running" in that gap and re-attaches, which spawns
        // `lms` and brings LM Studio straight back. That is the resurrection loop of #60 rebuilt
        // from the other side; measured it happening before this edge check existed. Requiring
        // false→true means the only thing that can attach is a scan that freshly saw the app alive.
        let attach = Self.shouldAttach(running: running, wasRunning: wasRunning, attached: attached)
        let detach = Self.shouldDetach(running: running, attached: attached)
        wasRunning = running
        lock.unlock()

        if attach, let bin = Self.lmsBinary() {
            Thread.detachNewThread { [weak self] in self?.runLMStudioStream(bin) }
        } else if detach {
            lock.lock()
            let proc = stream
            stream = nil
            // A rate from a runtime that has since quit describes nothing current.
            lmStudio = nil
            lock.unlock()
            proc?.terminate()
        }
    }

    /// The rate to publish now: the live HTTP gauge when a llama.cpp server answers, otherwise the
    /// last prediction LM Studio reported. Preferring HTTP is deliberate — that number describes the
    /// present, while the stream's may be hours old.
    /// `llamaCppPort` is where a llama.cpp server was OBSERVED to be running
    /// (`AIRuntimeSample.llamaCppPort`); pass nil when none is. Nil means no HTTP request is made
    /// at all — this watcher no longer owns a list of ports to try, because owning one is exactly
    /// how it ended up polling two localhost ports forever on machines with no runtime (#53).
    ///
    /// `lmStudioRunning` is likewise an observation: true only when an LM Studio process was seen.
    /// It is what attaches and detaches the log stream, so a machine where LM Studio is not running
    /// never causes it to start.
    public func latest(llamaCppPort: Int?, lmStudioRunning: Bool) -> FleetTokenRate? {
        syncLMStudioStream(running: lmStudioRunning)
        if let port = llamaCppPort, let r = readLlamaCppRate(port: port) { return r }
        lock.lock(); defer { lock.unlock() }
        return lmStudio
    }

    // MARK: - llama.cpp

    private func readLlamaCppRate(port: Int) -> FleetTokenRate? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/metrics"),
              let text = Self.getSync(url, timeout: 1.5),
              let v = Self.parsePrometheus(text, key: "llamacpp:predicted_tokens_seconds")
        else { return nil }
        return FleetTokenRate(tokensPerSec: v, source: "llama.cpp", model: nil,
                              measuredAt: Int64(Date().timeIntervalSince1970 * 1000), ttftSec: nil)
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
        lock.lock(); stream = proc; lock.unlock()
        defer {
            if proc.isRunning { proc.terminate() }
            // Clear the slot only if it is still ours: a detach already replaced it with nil, and
            // stomping that would leave `syncLMStudioStream` believing nothing is attached.
            lock.lock(); if stream === proc { stream = nil }; lock.unlock()
        }

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
