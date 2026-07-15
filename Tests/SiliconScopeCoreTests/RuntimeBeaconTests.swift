//
//  File:      RuntimeBeaconTests.swift
//  Created:   2026-07-15
//  Developer: Vincent Gourbin
//  Overview:  Tests for RuntimeBeaconReader (manifest decoding, dead-pid GC,
//             freshest-wins on nested operations) and for the AIRuntimeSampler
//             beacon merge (beacon identifies unmatched hosts; path identity
//             keeps naming matched ones; beacon activity rides along).
//  Notes:     Each test writes into its own temp directory — the real
//             ~/Library/Application Support/ai-runtime-beacons/ is never touched.
//             Live-pid manifests use our own pid; dead-pid ones use 99999997,
//             outside macOS's pid range, so kill(pid, 0) reliably ESRCHes.
//
import XCTest
@testable import SiliconScopeCore

final class RuntimeBeaconTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beacon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeManifest(_ json: String, filename: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(filename))
    }

    private func ltxManifest(pid: Int32, phase: String = "denoising",
                             step: Int = 3, updatedAt: String = "2026-07-15T09:00:42Z") -> String {
        """
        {"version": 1, "pid": \(pid), "runtime": "ltx-video-swift-mlx",
         "displayName": "LTX-Video", "task": "generate", "model": "distilled",
         "phase": "\(phase)", "step": \(step), "totalSteps": 11,
         "startedAt": "2026-07-15T09:00:00Z", "updatedAt": "\(updatedAt)"}
        """
    }

    // MARK: - RuntimeBeaconReader

    func testMissingDirectoryReturnsEmpty() {
        let reader = RuntimeBeaconReader(directory: dir.appendingPathComponent("nope"))
        XCTAssertTrue(reader.read().isEmpty)
    }

    func testReadsLiveManifestAndDecodesFields() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try writeManifest(ltxManifest(pid: pid), filename: "\(pid)-abc123.json")

        let beacons = RuntimeBeaconReader(directory: dir).read()
        let m = try XCTUnwrap(beacons[pid])
        XCTAssertEqual(m.runtime, "ltx-video-swift-mlx")
        XCTAssertEqual(m.displayName, "LTX-Video")
        XCTAssertEqual(m.task, "generate")
        XCTAssertEqual(m.model, "distilled")
        XCTAssertEqual(m.phase, "denoising")
        XCTAssertEqual(m.step, 3)
        XCTAssertEqual(m.totalSteps, 11)
        XCTAssertNotNil(m.updatedAt)
    }

    func testDeadPidManifestIsDeletedOnRead() throws {
        try writeManifest(ltxManifest(pid: 99999997), filename: "99999997-dead.json")

        XCTAssertTrue(RuntimeBeaconReader(directory: dir).read().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("99999997-dead.json").path))
    }

    func testFreshestManifestWinsForNestedOperations() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try writeManifest(ltxManifest(pid: pid, phase: "loading", step: 1,
                                      updatedAt: "2026-07-15T09:00:10Z"),
                          filename: "\(pid)-outer.json")
        try writeManifest(ltxManifest(pid: pid, phase: "denoising", step: 5,
                                      updatedAt: "2026-07-15T09:00:50Z"),
                          filename: "\(pid)-inner.json")

        let m = try XCTUnwrap(RuntimeBeaconReader(directory: dir).read()[pid])
        XCTAssertEqual(m.phase, "denoising")
        XCTAssertEqual(m.step, 5)
    }

    func testUndecodableAndMismatchedManifestsAreSkipped() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try writeManifest("not json at all", filename: "\(pid)-garbage.json")
        // pid in JSON body must match the filename's pid (spoof guard).
        try writeManifest(ltxManifest(pid: 42), filename: "\(pid)-spoof.json")

        XCTAssertTrue(RuntimeBeaconReader(directory: dir).read().isEmpty)
    }

    // MARK: - AIRuntimeKind mapping

    func testBeaconRuntimeMapping() {
        XCTAssertEqual(AIRuntimeKind.fromBeaconRuntime("ltx-video-swift-mlx"), .ltxVideo)
        XCTAssertEqual(AIRuntimeKind.fromBeaconRuntime("some-future-framework"), .beacon)
    }

    // MARK: - AIRuntimeSampler merge

    func testBeaconIdentifiesHostAppInvisibleToPathMatching() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try writeManifest(ltxManifest(pid: pid), filename: "\(pid)-abc.json")

        let sampler = AIRuntimeSampler(beaconReader: RuntimeBeaconReader(directory: dir))
        // A host app embedding the framework: nothing in path/name/args says LTX.
        let rows = [ProcessRow(pid: pid, name: "MyVideoApp", cpuPercent: 42, memoryBytes: 1 << 30,
                               path: "/Applications/MyVideoApp.app/Contents/MacOS/MyVideoApp")]
        let sample = sampler.sample(from: rows)

        XCTAssertEqual(sample.processes.count, 1)
        let proc = try XCTUnwrap(sample.processes.first)
        XCTAssertEqual(proc.kind, .ltxVideo)
        XCTAssertEqual(proc.displayName, "LTX-Video")
        XCTAssertEqual(proc.beacon?.task, "generate")
        XCTAssertEqual(proc.beacon?.progress ?? 0, 3.0 / 11.0, accuracy: 0.001)
    }

    func testBeaconVanishesWithManifest() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = "\(pid)-abc.json"
        try writeManifest(ltxManifest(pid: pid), filename: file)

        let sampler = AIRuntimeSampler(beaconReader: RuntimeBeaconReader(directory: dir))
        let rows = [ProcessRow(pid: pid, name: "MyVideoApp", cpuPercent: 0, memoryBytes: 0,
                               path: "/Applications/MyVideoApp.app/Contents/MacOS/MyVideoApp")]
        XCTAssertEqual(sampler.sample(from: rows).processes.count, 1)

        // Generation over → producer deleted its manifest → next scan shows nothing,
        // even though the (cached) process row is still there.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        XCTAssertTrue(sampler.sample(from: rows).processes.isEmpty)
    }

    func testPathIdentityKeepsNamingButGainsBeaconActivity() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try writeManifest(ltxManifest(pid: pid), filename: "\(pid)-abc.json")

        let sampler = AIRuntimeSampler(beaconReader: RuntimeBeaconReader(directory: dir))
        // The CLI binary is already identified by basename; the beacon adds activity.
        let rows = [ProcessRow(pid: pid, name: "ltx-video", cpuPercent: 0, memoryBytes: 0,
                               path: "/Users/x/.xcodebuild/Build/Products/Release/ltx-video")]
        let proc = try XCTUnwrap(sampler.sample(from: rows).processes.first)
        XCTAssertEqual(proc.kind, .ltxVideo)
        XCTAssertEqual(proc.beacon?.phase, "denoising")
    }
}
