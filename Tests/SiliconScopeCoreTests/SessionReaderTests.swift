//
//  File:      SessionReaderTests.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for SessionReader / LoadedRecording — load + per-frame derived precompute
//             (peak fold via MetricsEngine), index(forTime:) binary search, historyWindow trailing
//             rebuild, and the load error cases (empty / missing meta / no frames / newer version).
//  Notes:     Files are hand-encoded with the same JSONEncoder settings the recorder uses (.iso8601).
//
import XCTest
@testable import SiliconScopeCore

final class SessionReaderTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ssr-" + UUID().uuidString + ".ssrec")
    }
    private var enc: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    private func writeLines(_ datas: [Data], to url: URL) throws {
        var blob = Data()
        for d in datas { blob.append(d); blob.append(0x0A) }
        try blob.write(to: url)
    }
    private func meta(version: Int? = recordingFormatVersion) -> RecordingMeta {
        RecordingMeta(version: version, app: "test", chip: "Apple M1 Max", model: "MacBookPro18,2",
                      os: "macOS 14", started: Date(timeIntervalSince1970: 0), cadenceHz: 1, topology: nil)
    }
    private func frame(t: Double, bandwidth: Double) -> RecordedFrame {
        var s = SystemSnapshot(); s.bandwidth.cpuGBs = bandwidth
        return RecordedFrame(t: t, snapshot: s)
    }

    func testLoadAndPrecompute() throws {
        let url = tempURL()
        try writeLines([try enc.encode(meta()),
                        try enc.encode(frame(t: 0, bandwidth: 50)),
                        try enc.encode(frame(t: 1, bandwidth: 200)),
                        try enc.encode(frame(t: 2, bandwidth: 0))], to: url)
        let rec = try SessionReader.load(url)
        XCTAssertEqual(rec.count, 3)
        XCTAssertEqual(rec.duration, 2, accuracy: 0.001)
        XCTAssertEqual(rec.derived[1].bandwidthPeakGBs, 200, accuracy: 0.01)   // peak adopts 200
        XCTAssertGreaterThan(rec.derived[2].bandwidthPeakGBs, 199)             // slow decay
        XCTAssertEqual(rec.meta.chip, "Apple M1 Max")
        XCTAssertEqual(rec.meta.formatVersion, recordingFormatVersion)
    }

    func testIndexForTime() throws {
        let url = tempURL()
        try writeLines([try enc.encode(meta()),
                        try enc.encode(frame(t: 0, bandwidth: 0)),
                        try enc.encode(frame(t: 5, bandwidth: 0)),
                        try enc.encode(frame(t: 10, bandwidth: 0))], to: url)
        let rec = try SessionReader.load(url)
        XCTAssertEqual(rec.index(forTime: -1), 0)
        XCTAssertEqual(rec.index(forTime: 4), 0)
        XCTAssertEqual(rec.index(forTime: 5), 1)
        XCTAssertEqual(rec.index(forTime: 100), 2)
    }

    func testHistoryWindow() throws {
        let url = tempURL()
        var datas = [try enc.encode(meta())]
        for i in 0..<70 { datas.append(try enc.encode(frame(t: Double(i), bandwidth: 0))) }
        try writeLines(datas, to: url)
        let rec = try SessionReader.load(url)
        XCTAssertEqual(rec.historyWindow(upTo: 69).bandwidth.count, 60)   // trailing 60
        XCTAssertEqual(rec.historyWindow(upTo: 5).bandwidth.count, 6)     // frames 0...5
    }

    func testLoadErrors() throws {
        let empty = tempURL(); try Data().write(to: empty)
        XCTAssertThrowsError(try SessionReader.load(empty)) {
            XCTAssertEqual($0 as? SessionReader.LoadError, .empty)
        }
        let noMeta = tempURL(); try writeLines([Data("{\"foo\":1}".utf8)], to: noMeta)
        XCTAssertThrowsError(try SessionReader.load(noMeta)) {
            XCTAssertEqual($0 as? SessionReader.LoadError, .missingMeta)
        }
        let noFrames = tempURL(); try writeLines([try enc.encode(meta())], to: noFrames)
        XCTAssertThrowsError(try SessionReader.load(noFrames)) {
            XCTAssertEqual($0 as? SessionReader.LoadError, .noFrames)
        }
        let newer = tempURL()
        try writeLines([try enc.encode(meta(version: 999)), try enc.encode(frame(t: 0, bandwidth: 0))], to: newer)
        XCTAssertThrowsError(try SessionReader.load(newer)) {
            XCTAssertEqual($0 as? SessionReader.LoadError, .unsupportedVersion(999))
        }
    }
}
