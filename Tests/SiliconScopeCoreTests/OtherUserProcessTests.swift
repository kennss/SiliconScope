//
//  File:      OtherUserProcessTests.swift
//  Created:   2026-10-22
//  Updated:   2026-10-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests how ProcessSampler sees other users' processes (#85): which of them count as
//             AI-runtime candidates from their path alone, how /bin/ps's lines are read, and a live
//             read of a root process through ps.
//  Notes:     The live test reads launchd (pid 1, root), which every Mac runs and libproc refuses
//             to describe to a normal user — the same position as an "ai" account's Ollama. The ps
//             fixtures are real lines from macOS 27's /bin/ps (2026-10-22).
//
import XCTest
@testable import SiliconScopeCore

final class OtherUserProcessTests: XCTestCase {

    // MARK: - Candidates, from the path alone

    func testRuntimePathsAreCandidates() {
        // A runtime's own binary, bundle or support directory names it without argv.
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/opt/homebrew/bin/ollama"))
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/Applications/Ollama.app/Contents/Resources/ollama"))
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/Applications/oMLX.app/Contents/MacOS/oMLX"))
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/Users/ai/.lmstudio/.internal/utils/node"))
    }

    func testInterpretersAreCandidates() {
        // A pip-installed oMLX or mlx_lm runs as python; only its argv says which.
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/opt/homebrew/bin/python3.12"))
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path: "/usr/local/bin/llama-server"))
        // A venv on Homebrew's or python.org's Python runs as the framework build's `Python`.
        XCTAssertTrue(ProcessSampler.mayBeAIRuntime(path:
            "/opt/homebrew/Cellar/python@3.14/3.14.3_1/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"))
    }

    func testSystemProcessesAreNot() {
        // What other users' processes on a Mac mostly are: none may start a ps read.
        XCTAssertFalse(ProcessSampler.mayBeAIRuntime(path: "/sbin/launchd"))
        XCTAssertFalse(ProcessSampler.mayBeAIRuntime(path: "/usr/sbin/mDNSResponder"))
        XCTAssertFalse(ProcessSampler.mayBeAIRuntime(path: "/usr/libexec/locationd"))
        XCTAssertFalse(ProcessSampler.mayBeAIRuntime(path: ""))
    }

    // MARK: - ps output

    func testParsesPSLines() {
        let text = """
              1  30704 227:53.69 /sbin/launchd
            408 168176  73:45.92 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds
           3192   3504   0:00.01 /opt/homebrew/bin/ollama serve  --verbose
           """
        let read = ProcessSampler.parsePS(text)
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read[1], ProcessSampler.PSRead(residentBytes: 30704 * 1024,
                                                      cpuNs: 13_673_690_000_000, args: "/sbin/launchd"))
        XCTAssertEqual(read[408]?.residentBytes, 168_176 * 1024)
        // argv keeps its own spacing.
        XCTAssertEqual(read[3192]?.args, "/opt/homebrew/bin/ollama serve  --verbose")
        XCTAssertEqual(read[3192]?.cpuNs, 10_000_000)
    }

    func testSkipsLinesItCannotRead() {
        let read = ProcessSampler.parsePS("garbage\n  12  x  0:00.01 /bin/zsh\n  13  400  0:01.50 /bin/sh\n")
        XCTAssertEqual(Array(read.keys), [13])
    }

    func testCPUTimeFormats() {
        func ns(_ s: String) -> UInt64? { ProcessSampler.psTimeNanoseconds(Substring(s)) }
        XCTAssertEqual(ns("0:00.01"), 10_000_000)
        XCTAssertEqual(ns("227:53.69"), 13_673_690_000_000)      // macOS: minutes are unbounded
        XCTAssertEqual(ns("1:02:03.50"), 3_723_500_000_000)      // hours:minutes:seconds
        XCTAssertEqual(ns("2-00:00:01.00"), 172_801_000_000_000) // a days prefix
        XCTAssertNil(ns(""))
        XCTAssertNil(ns("1:2:3:4"))
        XCTAssertNil(ns("x:00.01"))
    }

    // MARK: - Live

    /// launchd is root's: libproc refuses its memory to us, /bin/ps reads it.
    func testReadsARootProcessThroughPS() {
        let read = ProcessSampler.readThroughPS([1])
        guard let launchd = read[1] else { return XCTFail("ps did not report pid 1") }
        XCTAssertGreaterThan(launchd.residentBytes, 1024 * 1024)
        XCTAssertGreaterThan(launchd.cpuNs, 0)
        XCTAssertEqual(launchd.args, "/sbin/launchd")
    }

    /// A pid that is gone is absent, and does not cost the ones still running. (It must be a real
    /// pid number: one above the kernel's 99,999 makes ps refuse the whole list.)
    func testAGonePIDIsAbsent() {
        guard let gone = (2...99_999).reversed().lazy.map({ pid_t($0) })
            .first(where: { kill($0, 0) == -1 && errno == ESRCH }) else { return XCTFail("no free pid") }
        let read = ProcessSampler.readThroughPS([1, gone])
        XCTAssertNotNil(read[1])
        XCTAssertNil(read[gone])
    }

    /// The table still holds only this user's processes; root's launchd is never one of them, and
    /// it is no AI candidate, so it is not in otherUsers either.
    func testTableKeepsOtherUsersOut() {
        let table = ProcessSampler().sample()
        XCTAssertFalse(table.rows.isEmpty)
        XCTAssertFalse(table.rows.contains { $0.pid == 1 })
        XCTAssertFalse(table.otherUsers.contains { $0.pid == 1 })
        XCTAssertTrue(table.rows.contains { $0.pid == getpid() })
    }
}
