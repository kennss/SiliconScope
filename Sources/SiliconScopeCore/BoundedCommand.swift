//
//  File:      BoundedCommand.swift
//  Created:   2026-10-29
//  Updated:   2026-10-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Runs a short-lived system tool (system_profiler, ps) with a deadline and returns
//             its stdout. A tool that wedges is killed instead of being waited on forever (#86).
//  Notes:     ⚠️ Every tool the sampling path runs must go through here. The loop measures one
//             tick at a time, so a single unbounded `waitUntilExit()` that never returns stops
//             every reading in the app at once — the dashboard keeps showing the last frame as if
//             it were live, and only a restart brings it back. That is what #86 reported.
//
//             stdout is drained on its own thread while the process runs: a child that fills the
//             pipe (64 KiB) blocks on write and would never exit if nobody read it.
//             On timeout: SIGTERM, then SIGKILL one second later. The drain thread ends when the
//             pipe closes — at once for these tools, which spawn no children of their own.
//
import Foundation
import os

public enum BoundedCommand {

    /// Runs `path` with `arguments` and returns everything it wrote to stdout, or nil when it could
    /// not start or did not finish within `timeout` seconds. stderr is discarded; the exit status is
    /// not judged — callers parse what was printed, which is what the tools above need.
    public static func run(_ path: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let output = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let data = reader.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return nil
        }
        // The process is gone, so stdout reaches EOF as soon as the drain catches up. Bounded as
        // well, so nothing here can outlive the deadline by more than a second.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        return output.withLock { $0 }
    }
}
