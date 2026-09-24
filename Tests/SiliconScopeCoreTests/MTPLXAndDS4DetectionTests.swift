//
//  File:      MTPLXAndDS4DetectionTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in how MTPLX (youssofal/MTPLX) and DS4 (antirez/ds4) are recognised, and —
//             the part that matters more — which of their processes may be asked for a model.
//  Notes:     Both default to 127.0.0.1:8000, the same port as oMLX and Rapid-MLX, and both ship
//             CLIs that load a model without serving it. A port assumed for a process that serves
//             nothing is a request to someone else's server (#53). argv strings follow the
//             projects' documented invocations; they are representative, not captured live.
//
import XCTest
@testable import SiliconScopeCore

final class MTPLXAndDS4DetectionTests: XCTestCase {

    private func kind(_ path: String, _ args: String? = nil) -> AIRuntimeKind? {
        AIRuntimeKind.match(path: path, name: (path as NSString).lastPathComponent, args: args)
    }

    private func sample(_ procs: [(AIRuntimeKind, String, String?)]) -> AIRuntimeSample {
        var s = AIRuntimeSample()
        s.processes = procs.enumerated().map { i, p in
            AIRuntimeProcess(pid: Int32(100 + i), kind: p.0, displayName: p.0.displayName,
                             cpuPercent: 0, memoryBytes: 4 << 30,
                             embeddedPort: AIRuntimeKind.servingPort(kind: p.0, path: p.1, args: p.2))
        }
        return s
    }

    // MARK: - MTPLX

    func testMTPLXConsoleScriptIsMTPLX() {
        let py = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/bin/python3.12"
        XCTAssertEqual(kind(py, "\(py) /opt/homebrew/bin/mtplx serve --model mlx-community/Qwen3-8B-4bit"), .mtplx)
        XCTAssertEqual(kind(py, "\(py) /Users/x/.local/bin/mtplx"), .mtplx)
    }

    func testMTPLXModuleInvocationIsMTPLX() {
        XCTAssertEqual(kind("/usr/bin/python3", "python3 -m mtplx serve --port 8123"), .mtplx)
        XCTAssertEqual(kind("/usr/bin/python3", "python3 -m mtplx"), .mtplx)
    }

    func testMTPLXAppAndLauncherAreMTPLX() {
        XCTAssertEqual(kind("/Applications/MTPLX.app/Contents/MacOS/MTPLX"), .mtplx)
        XCTAssertEqual(kind("/opt/homebrew/bin/mtplx", "/opt/homebrew/bin/mtplx start"), .mtplx)
    }

    /// A cache or checkout folder named after MTPLX in some other process's argv is not MTPLX.
    func testMTPLXPathsInUnrelatedArgvDoNotMatch() {
        XCTAssertNotEqual(kind("/usr/bin/python3", "python3 train.py --cache-dir /Users/x/mtplx-models"), .mtplx)
        XCTAssertNotEqual(kind("/usr/bin/python3", "python3 /Users/x/src/mtplx/tools/convert.py"), .mtplx)
        XCTAssertNotEqual(kind("/usr/bin/python3", "python3 -m mtplx_extras serve"), .mtplx)
    }

    func testOnlyAServingMTPLXHasAPort() {
        let py = "/usr/bin/python3"
        XCTAssertEqual(AIRuntimeKind.servingPort(kind: .mtplx, path: py, args: "python3 -m mtplx serve"), 8000)
        XCTAssertEqual(AIRuntimeKind.servingPort(kind: .mtplx, path: py, args: "\(py) /opt/homebrew/bin/mtplx start --port 9001"), 9001)
        XCTAssertNil(AIRuntimeKind.servingPort(kind: .mtplx, path: py, args: "python3 -m mtplx chat"))
        XCTAssertNil(AIRuntimeKind.servingPort(kind: .mtplx, path: "/Applications/MTPLX.app/Contents/MacOS/MTPLX", args: nil))
        // `serve` must be MTPLX's subcommand, not a word elsewhere in the line.
        XCTAssertFalse(AIRuntimeKind.isMTPLXServer(args: "python3 -m mtplx chat --prompt serve"))
    }

    // MARK: - DS4

    func testEveryDS4BinaryIsDS4() {
        for b in ["ds4", "ds4-server", "ds4-agent", "ds4-bench", "ds4-eval"] {
            XCTAssertEqual(kind("/Users/x/ds4/\(b)"), .ds4, b)
        }
    }

    /// "ds4" is short; only exact binary names count. ds4drv is a DualShock 4 driver.
    func testDS4LookalikesAreNotDS4() {
        XCTAssertNil(kind("/usr/local/bin/ds4drv"))
        XCTAssertNil(kind("/usr/local/bin/ds4windows"))
        XCTAssertNil(kind("/usr/local/bin/pyds4"))
    }

    func testOnlyDS4ServerHasAPort() {
        XCTAssertEqual(AIRuntimeKind.servingPort(kind: .ds4, path: "/x/ds4-server", args: nil), 8000)
        XCTAssertEqual(AIRuntimeKind.servingPort(kind: .ds4, path: "/x/ds4-server",
                                                 args: "/x/ds4-server -m ds4flash.gguf --port 8811"), 8811)
        XCTAssertNil(AIRuntimeKind.servingPort(kind: .ds4, path: "/x/ds4", args: nil))
        XCTAssertNil(AIRuntimeKind.servingPort(kind: .ds4, path: "/x/ds4-agent", args: nil))
    }

    // MARK: - Where the probe goes

    /// ⚠️ The #53 case. DS4's CLI holds a model, oMLX owns :8000. Asking :8000 "for DS4" would
    /// return oMLX's model under DS4's name.
    func testADS4CLIAloneGivesNothingToAsk() {
        let s = sample([(.ds4, "/x/ds4", nil), (.omlx, "/Applications/oMLX.app/Contents/MacOS/omlx-server", nil)])
        XCTAssertNil(s.apiPort(for: .ds4))
    }

    func testTheServersPortIsTheOneAsked() {
        let s = sample([(.ds4, "/x/ds4", nil), (.ds4, "/x/ds4-server", "/x/ds4-server --port 8811")])
        XCTAssertEqual(s.apiPort(for: .ds4), 8811)
        let m = sample([(.mtplx, "/Applications/MTPLX.app/Contents/MacOS/MTPLX", nil),
                        (.mtplx, "/usr/bin/python3", "python3 -m mtplx serve")])
        XCTAssertEqual(m.apiPort(for: .mtplx), 8000)
        XCTAssertNil(sample([(.mtplx, "/Applications/MTPLX.app/Contents/MacOS/MTPLX", nil)]).apiPort(for: .mtplx))
    }

    /// The settings still own the three configurable runtimes, and llama.cpp is still observe-only.
    func testConfiguredAndDocumentedPortsStillResolve() {
        let ports = RuntimePorts(ollama: 21434, lmStudio: 2234, omlx: 9000)
        let empty = AIRuntimeSample()
        XCTAssertEqual(empty.apiPort(for: .ollama, configured: ports), 21434)
        XCTAssertEqual(empty.apiPort(for: .lmStudio, configured: ports), 2234)
        XCTAssertEqual(empty.apiPort(for: .omlx, configured: ports), 9000)
        XCTAssertEqual(empty.apiPort(for: .exo), 52415)
        XCTAssertNil(empty.apiPort(for: .llamaCpp))
        XCTAssertNil(empty.apiPort(for: .spectaling))
    }

    // MARK: - Recordings

    /// A recording names the runtime that answered. One a build does not know must read as
    /// unattributed, not make the frame — and with it the file — undecodable.
    func testAnUnknownSourceDoesNotBreakDecoding() throws {
        let json = #"{"status":"ok","source":"someFutureRuntime","loadedModels":[]}"#
        let s = try JSONDecoder().decode(RuntimeAPISample.self, from: Data(json.utf8))
        XCTAssertEqual(s.status, .ok)
        XCTAssertNil(s.source)
        var mt = RuntimeAPISample(); mt.status = .ok; mt.source = .ds4
        let back = try JSONDecoder().decode(RuntimeAPISample.self, from: JSONEncoder().encode(mt))
        XCTAssertEqual(back.source, .ds4)
    }
}
