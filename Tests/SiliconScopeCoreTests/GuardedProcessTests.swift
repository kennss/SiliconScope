//
//  File:      GuardedProcessTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in that a child SiliconScope starts cannot outlive it — the orphaned
//             `lms log stream` processes found reparented to launchd after the app was stopped.
//  Notes:     Real processes, not mocks: the property under test is kernel behaviour (a pipe's
//             reader seeing end-of-file when its writer's process ends). `/bin/sleep` stands in for
//             `lms` so the tests need neither LM Studio nor a network. Closing the lifeline in-process
//             is exactly what the kernel does to it when this process dies, SIGKILL included.
//
import XCTest
@testable import SiliconScopeCore

final class GuardedProcessTests: XCTestCase {

    private func childPID(of guardian: Int32) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(guardian)]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").first.flatMap { Int32($0) }
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return cond()
    }

    private func started() throws -> (Process, Pipe, Int32) {
        let (proc, lifeline) = TokenRateWatcher.guardedProcess(executable: "/bin/sleep", arguments: ["300"])
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        var child: Int32?
        XCTAssertTrue(waitUntil { child = childPID(of: proc.processIdentifier); return child != nil })
        return (proc, lifeline, try XCTUnwrap(child))
    }

    /// ⚠️ The bug. When this process goes away its end of the lifeline closes — and the child must
    /// go with it, instead of being reparented to launchd and running for the rest of the session.
    func testTheChildDiesWhenItsParentGoesAway() throws {
        let (proc, lifeline, child) = try started()
        XCTAssertTrue(isAlive(child))
        try lifeline.fileHandleForWriting.close()               // what the kernel does when we die
        XCTAssertTrue(waitUntil { !isAlive(child) }, "child \(child) outlived its parent")
        XCTAssertTrue(waitUntil { !proc.isRunning })
    }

    /// Detaching on purpose (LM Studio quit) terminates the guardian; that has to reach the child.
    func testTerminatingTheGuardianStopsTheChild() throws {
        let (proc, lifeline, child) = try started()
        proc.terminate()
        XCTAssertTrue(waitUntil { !isAlive(child) }, "terminate() stopped the guardian but not \(child)")
        withExtendedLifetime(lifeline) {}
    }

    /// The reader treats end-of-stream as "LM Studio quit". The guardian must not hold our output
    /// pipe open, or a finished child would look like a stream that is still running.
    func testAChildThatExitsStillEndsTheStream() throws {
        let (proc, lifeline) = TokenRateWatcher.guardedProcess(executable: "/bin/echo", arguments: ["hello"])
        let out = Pipe(); proc.standardOutput = out
        try proc.run()
        let expectation = expectation(description: "end of stream")
        DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()   // returns only at EOF
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello\n")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        proc.terminate()
        withExtendedLifetime(lifeline) {}
    }
}
