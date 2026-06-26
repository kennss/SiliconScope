//
//  File:      SessionRecorderTests.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for SessionRecorder — CSV integrity (header/row alignment, blank cells for
//             unavailable metrics, value formatting), the 1 Hz cadence gate, top-N process
//             trimming, and the record-to-file → CSV round trip.
//  Notes:     Pure CSV helpers are tested without I/O; recording tests use a unique temp dir.
//
import XCTest
@testable import SiliconScopeCore

final class SessionRecorderTests: XCTestCase {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ssrec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // Every data row must have exactly as many columns as the header.
    func testCSVHeaderRowAlignment() {
        var s = SystemSnapshot()
        s.power.cpuWatts = 5; s.battery.hasBattery = true; s.battery.percent = 80
        let row = SessionRecorder.csvRow(s, t: 1, started: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count,
                       SessionRecorder.csvColumns.count)
    }

    func testCSVRowValues() {
        var s = SystemSnapshot()
        s.power.cpuWatts = 5; s.power.aneWatts = 2.5
        let row = SessionRecorder.csvRow(s, t: 1, started: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(row.contains("5.00"))          // cpu_w
        XCTAssertTrue(row.contains("2.50"))          // ane_w
        XCTAssertTrue(row.hasPrefix("1970-01-01"))   // timestamp = started + t
    }

    // No fans → the fan cell is blank, not "0" (honest absence).
    func testBlankCellForUnavailable() {
        let cols = SessionRecorder.csvColumns
        let vals = SessionRecorder.csvRow(SystemSnapshot(), t: 0, started: Date())
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(vals[cols.firstIndex(of: "fan_rpm")!], "")
    }

    func testRecordToFileAndCSV() throws {
        let rec = SessionRecorder(cadence: 0, maxProcesses: 30)   // no gate → every append records
        try rec.start(directory: tempDir())
        var s = SystemSnapshot(); s.power.cpuWatts = 7
        rec.append(s); rec.append(s); rec.append(s)
        rec.stop()
        XCTAssertEqual(rec.sampleCount, 3)
        let csv = try SessionRecorder.csv(fromRecordingAt: rec.fileURL!)
        XCTAssertEqual(csv.split(separator: "\n").count, 4)   // header + 3 rows
        XCTAssertTrue(csv.contains("7.00"))
    }

    // The 1 Hz gate: rapid appends within `cadence` record only the first.
    func testCadenceGate() throws {
        let rec = SessionRecorder(cadence: 100, maxProcesses: 30)
        try rec.start(directory: tempDir())
        let s = SystemSnapshot()
        rec.append(s); rec.append(s); rec.append(s)
        rec.stop()
        XCTAssertEqual(rec.sampleCount, 1)
    }

    // Processes are trimmed to the top N per frame.
    func testProcessTrim() throws {
        let rec = SessionRecorder(cadence: 0, maxProcesses: 5)
        try rec.start(directory: tempDir())
        var s = SystemSnapshot()
        s.processes = (0..<50).map { ProcessRow(pid: Int32($0), name: "p\($0)", cpuPercent: 0, memoryBytes: 0) }
        rec.append(s)
        rec.stop()
        let text = try String(contentsOf: rec.fileURL!, encoding: .utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let frameLine = text.split(separator: "\n").dropFirst().first!   // skip the meta line
        let frame = try dec.decode(RecordedFrame.self, from: Data(frameLine.utf8))
        XCTAssertEqual(frame.snapshot.processes.count, 5)
    }
}
