//
//  File:      AIRuntimeMatchTests.swift
//  Created:   2026-06-14
//  Updated:   2026-07-02
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Adversarial tests for AIRuntimeKind.match — the bundle-first, two-stage
//             classifier. Locks in the cases that must NOT regress (Ollama runner is not
//             llama.cpp; generic server/main are not runtimes; empty path never crashes;
//             the short "exo" substring never false-positives on hexo/Plexos/nexo).
//  Notes:     argv strings are REPRESENTATIVE, not pinned from a live run (the runner's
//             --port is dynamic). The logic under test is pure (path/name/args -> kind),
//             so synthetic inputs exercise it deterministically.
//
import XCTest
@testable import SiliconScopeCore

final class AIRuntimeMatchTests: XCTestCase {

    // Ollama's llama-server runner child must resolve to .ollama via bundle/.ollama path,
    // NEVER .llamaCpp (the collision the bundle-first rule exists to prevent).
    func testOllamaRunnerIsOllamaNotLlamaCpp() {
        let path = "/Applications/Ollama.app/Contents/Resources/llama-server"
        let args = "/Applications/Ollama.app/Contents/Resources/llama-server " +
                   "--model /Users/x/.ollama/models/blobs/sha256-abc --port 54321 --host 127.0.0.1 -c 8192"
        XCTAssertEqual(AIRuntimeKind.match(path: path, name: "llama-server", args: args), .ollama)
        XCTAssertEqual(AIRuntimeKind.embeddedPort(args: args), 54321)
    }

    func testOllamaParentAndServeBothOllama() {
        XCTAssertEqual(AIRuntimeKind.match(path: "/Applications/Ollama.app/Contents/MacOS/Ollama",
                                           name: "Ollama", args: nil), .ollama)
        XCTAssertEqual(AIRuntimeKind.match(path: "/Applications/Ollama.app/Contents/Resources/ollama",
                                           name: "ollama", args: "ollama serve"), .ollama)
    }

    // A bare llama.cpp build (no Ollama/LM Studio in path) is .llamaCpp.
    func testBareLlamaServerIsLlamaCpp() {
        XCTAssertEqual(AIRuntimeKind.match(path: "/Users/x/llama.cpp/build/bin/llama-server",
                                           name: "llama-server", args: "--port 8080"), .llamaCpp)
    }

    // Generic binaries named server/main must NOT match.
    func testGenericBinariesDoNotMatch() {
        XCTAssertNil(AIRuntimeKind.match(path: "/usr/sbin/server", name: "server", args: nil))
        XCTAssertNil(AIRuntimeKind.match(path: "/usr/bin/main", name: "main", args: nil))
    }

    func testMLXViaArgsButNotBarePython() {
        let py = "/opt/homebrew/bin/python3.11"
        XCTAssertEqual(AIRuntimeKind.match(path: py, name: "python3.11",
                                           args: "python -m mlx_lm.server --model mlx-community/x"), .mlx)
        XCTAssertNil(AIRuntimeKind.match(path: py, name: "python3.11", args: "python -m http.server"))
    }

    func testLMStudioBundleAndBinary() {
        XCTAssertEqual(AIRuntimeKind.match(path: "/Applications/LM Studio.app/Contents/Resources/llama-server",
                                           name: "llama-server", args: nil), .lmStudio)
        XCTAssertEqual(AIRuntimeKind.match(path: "/Users/x/.cache/lm-studio/bin/lms",
                                           name: "lms", args: nil), .lmStudio)
    }

    // Denied/empty path (system pid) must degrade to no match, no crash.
    func testEmptyPathNoMatch() {
        XCTAssertNil(AIRuntimeKind.match(path: "", name: "kernel_task", args: nil))
    }

    func testEmbeddedPortVariants() {
        XCTAssertEqual(AIRuntimeKind.embeddedPort(args: "x --port 1234 y"), 1234)
        XCTAssertEqual(AIRuntimeKind.embeddedPort(args: "x --port=8080 y"), 8080)
        XCTAssertNil(AIRuntimeKind.embeddedPort(args: "x --host 127.0.0.1 y"))
        XCTAssertNil(AIRuntimeKind.embeddedPort(args: nil))
    }

    // Rapid-MLX (OpenAI-compatible MLX engine) resolves to .rapidMLX, not bare .mlx.
    func testRapidMLXMatch() {
        // Installed via uv / pip / brew → a `rapid-mlx` wrapper binary.
        XCTAssertEqual(AIRuntimeKind.match(path: "/Users/x/.local/bin/rapid-mlx",
                                           name: "rapid-mlx", args: "rapid-mlx serve gemma-4-26b-4bit"), .rapidMLX)
        // Module invocation via python — argv carries rapid_mlx.
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/python3.12", name: "python3.12",
                                           args: "python -m rapid_mlx serve --port 8000"), .rapidMLX)
        // Must NOT be misclassified as bare MLX even with no argv.
        XCTAssertNotEqual(AIRuntimeKind.match(path: "/Users/x/.local/bin/rapid-mlx",
                                              name: "rapid-mlx", args: nil), .mlx)
    }

    func testOMLXMatch() {
        XCTAssertEqual(AIRuntimeKind.match(path: "/Applications/oMLX.app/Contents/MacOS/oMLX", name: "oMLX", args: nil), .omlx)
        XCTAssertEqual(AIRuntimeKind.match(path: "/Applications/omlx.app/Contents/MacOS/omlx", name: "omlx", args: nil), .omlx)
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/omlx", name: "omlx", args: nil), .omlx)
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/oMLX", name: "oMLX", args: nil), .omlx)
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/omlx-server", name: "omlx-server", args: nil), .omlx)
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/oMLX-server", name: "oMLX-server", args: nil), .omlx)
    }

    // exo (exo-explore/exo) — OpenAI-compatible cluster server on :52415. Matches its console
    // entry point / module file / source path across the three ways it's launched.
    func testExoMatch() {
        // Installed console script (`exo` command, e.g. from a venv/uv/pipx install).
        XCTAssertEqual(AIRuntimeKind.match(path: "/Users/x/.venv/bin/exo",
                                           name: "exo", args: "exo run llama-3.2-3b"), .exo)
        // Module invocation via python — argv carries `-m exo.main`.
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/python3.12", name: "python3.12",
                                           args: "python -m exo.main --inference-engine mlx"), .exo)
        // Running the source file directly.
        XCTAssertEqual(AIRuntimeKind.match(path: "/opt/homebrew/bin/python3.12", name: "python3.12",
                                           args: "python /Users/x/exo/exo/main.py"), .exo)
    }

    // The short "exo" substring must NOT false-positive on unrelated tools that merely contain it.
    func testExoDoesNotFalsePositive() {
        // hexo — a Node static-site generator (basename + path share "exo").
        XCTAssertNil(AIRuntimeKind.match(path: "/opt/homebrew/bin/hexo",
                                         name: "hexo", args: "node /opt/homebrew/bin/hexo generate"))
        XCTAssertNil(AIRuntimeKind.match(path: "/Users/x/Plexos/bin/plexos", name: "plexos", args: nil))
        XCTAssertNil(AIRuntimeKind.match(path: "/usr/local/bin/nexo", name: "nexo", args: "nexo serve"))
    }

    // primaryKind ranks by grouped RSS; the Ollama group (parent+runner) outweighs a small llama.cpp.
    func testPrimaryKindByGroupedRSS() {
        var s = AIRuntimeSample()
        s.processes = [
            .init(pid: 1, kind: .ollama, displayName: "Ollama", cpuPercent: 0, memoryBytes: 2 << 30, embeddedPort: nil),
            .init(pid: 2, kind: .ollama, displayName: "Ollama", cpuPercent: 0, memoryBytes: 14 << 30, embeddedPort: 54321),
            .init(pid: 3, kind: .llamaCpp, displayName: "llama.cpp", cpuPercent: 0, memoryBytes: 1 << 30, embeddedPort: nil),
        ]
        XCTAssertEqual(s.primaryKind, .ollama)
        XCTAssertEqual(s.primaryMemoryBytes, 16 << 30)
        XCTAssertEqual(s.ollamaEmbeddedPort, 54321)
    }
}
