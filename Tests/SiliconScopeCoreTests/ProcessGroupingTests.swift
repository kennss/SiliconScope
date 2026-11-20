//
//  File:      ProcessGroupingTests.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in how the process table folds into apps: by the outermost `.app` bundle on
//             the executable path, never by name. Also the display name of a process whose name
//             the kernel cut short.
//  Notes:     Paths are shaped like the ones libproc reports for Chrome's helpers on macOS 27.
//
import XCTest
@testable import SiliconScopeCore

final class ProcessGroupingTests: XCTestCase {

    private let chrome = "/Applications/Google Chrome.app"
    private func helper(_ kind: String) -> String {
        chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/142.0/Helpers/"
            + "Google Chrome Helper (\(kind)).app/Contents/MacOS/Google Chrome Helper (\(kind))"
    }
    private func row(_ pid: Int32, _ name: String, cpu: Double, mb: UInt64, path: String) -> ProcessRow {
        ProcessRow(pid: pid, name: name, cpuPercent: cpu, memoryBytes: mb << 20, path: path)
    }

    // MARK: - Bundle from path

    func testTheOutermostBundleWins() {
        let app = ProcessGrouping.outermostApp(path: helper("Renderer"))
        XCTAssertEqual(app?.path, chrome)
        XCTAssertEqual(app?.name, "Google Chrome")
    }

    func testNoBundleNoApp() {
        XCTAssertNil(ProcessGrouping.outermostApp(path: "/usr/libexec/mds_stores"))
        XCTAssertNil(ProcessGrouping.outermostApp(path: ""))
        // A component that is only ".app" is not a bundle name.
        XCTAssertNil(ProcessGrouping.outermostApp(path: "/tmp/.app/bin/tool"))
    }

    // MARK: - Names the kernel cut short

    /// proc_name keeps 32 bytes; the executable's file name has the rest.
    func testACutNameIsCompletedFromTheExecutable() {
        XCTAssertEqual(ProcessSampler.displayName(procName: "Google Chrome Helper (Aperitif",
                                                  basename: "Google Chrome Helper (Aperitif Renderer)"),
                       "Google Chrome Helper (Aperitif Renderer)")
    }

    /// A process that named itself keeps its own name; so does one whose path was denied.
    func testAChosenNameStands() {
        XCTAssertEqual(ProcessSampler.displayName(procName: "Code Helper", basename: "Electron Helper"), "Code Helper")
        XCTAssertEqual(ProcessSampler.displayName(procName: "kernel_task", basename: ""), "kernel_task")
        XCTAssertEqual(ProcessSampler.displayName(procName: "ollama", basename: "ollama"), "ollama")
    }

    // MARK: - Folding

    func testHelpersFoldIntoTheirApp() {
        let rows = [
            row(88954, "Google Chrome Helper (Renderer)", cpu: 100.5, mb: 356, path: helper("Renderer")),
            row(34864, "qemu-system-aarch64", cpu: 70.9, mb: 2699, path: "/opt/homebrew/bin/qemu-system-aarch64"),
            row(85457, "Google Chrome Helper (GPU)", cpu: 15.7, mb: 171, path: helper("GPU")),
            row(81373, "Google Chrome", cpu: 16.7, mb: 408, path: chrome + "/Contents/MacOS/Google Chrome"),
        ]
        let g = ProcessGrouping.groups(rows)
        XCTAssertEqual(g.map(\.name), ["Google Chrome", "qemu-system-aarch64"])
        XCTAssertEqual(g[0].count, 3)
        XCTAssertEqual(g[0].cpuPercent, 132.9, accuracy: 1e-9)
        XCTAssertEqual(g[0].memoryBytes, UInt64(356 + 171 + 408) << 20)
        XCTAssertEqual(g[0].members.map(\.pid), [88954, 81373, 85457], "members are busiest first")
        XCTAssertFalse(g[0].isSingleProcess)
        XCTAssertTrue(g[1].isSingleProcess)
    }

    /// Same name, different bundles: grouping is by where the app is, not what it is called.
    func testSameNameDifferentPlaceStaysApart() {
        let rows = [
            row(1, "Foo", cpu: 1, mb: 1, path: "/Applications/Foo.app/Contents/MacOS/Foo"),
            row(2, "Foo", cpu: 2, mb: 1, path: "/Users/x/Downloads/Foo.app/Contents/MacOS/Foo"),
        ]
        XCTAssertEqual(ProcessGrouping.groups(rows).count, 2)
    }

    /// A denied path can't be placed in any app, and two of them are not the same process.
    func testDeniedPathsStandAlone() {
        let rows = [row(10, "kernel_task", cpu: 5, mb: 1, path: ""),
                    row(11, "launchd", cpu: 5, mb: 1, path: "")]
        let g = ProcessGrouping.groups(rows)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.map(\.name), ["kernel_task", "launchd"], "ties break by name")
    }
}
