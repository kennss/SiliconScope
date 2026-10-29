//
//  File:      BoundedCommandTests.swift
//  Created:   2026-10-29
//  Updated:   2026-10-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins BoundedCommand's promise to the sampling loop (#86): output comes back whole,
//             and a tool that does not finish is killed within its deadline instead of holding
//             the caller forever — including one that ignores SIGTERM.
//
import XCTest
@testable import SiliconScopeCore

final class BoundedCommandTests: XCTestCase {

    func testReturnsStdout() {
        let out = BoundedCommand.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, "hello\n")
    }

    func testPassesEnvironment() {
        let out = BoundedCommand.run("/bin/sh", ["-c", "printf %s \"$PROBE\""],
                                     environment: ["PROBE": "set"], timeout: 5)
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, "set")
    }

    /// More than a pipe buffer (64 KiB): without a concurrent drain the child blocks on write and
    /// the call would end in a timeout instead of the data.
    func testLargeOutputDoesNotDeadlock() {
        let out = BoundedCommand.run("/bin/dd", ["if=/dev/zero", "bs=1024", "count=512"], timeout: 10)
        XCTAssertEqual(out?.count, 512 * 1024)
    }

    func testTimeoutKillsAndReturnsNil() {
        let start = Date()
        let out = BoundedCommand.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// A tool that ignores SIGTERM is still gone: `exec` keeps the ignored disposition, so only the
    /// SIGKILL that follows can end it.
    func testIgnoredSIGTERMStillEndsWithinDeadline() {
        let start = Date()
        let out = BoundedCommand.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.5)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testMissingExecutableReturnsNil() {
        XCTAssertNil(BoundedCommand.run("/nonexistent/tool", [], timeout: 1))
    }
}
