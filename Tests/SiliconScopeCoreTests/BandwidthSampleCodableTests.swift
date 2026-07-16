//
//  File:      BandwidthSampleCodableTests.swift
//  Created:   2026-07-16
//  Updated:   2026-07-16
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Backward-compatibility regression tests for BandwidthSample's Codable decoding.
//             Every .ssrec frame embeds a BandwidthSample; SessionReader skips any frame that
//             fails to decode, so if a NEWLY added BandwidthSample field is not tolerated when
//             absent, every pre-existing recording loses all its frames and opens as `.noFrames`.
//             These tests pin RecordingFormat.swift's policy ("additive fields stay backward-
//             compatible") at the exact struct where it is easiest to break: a non-optional field
//             added later (`isEstimated`) must decode to its default on files that predate it.
//  Notes:     Pure value-type Codable tests — no hardware, no file IO. The literal JSON shapes are
//             the on-disk frame shapes: pre-measuredTotalGBs, measuredTotalGBs-era, and current.
//
import XCTest
@testable import SiliconScopeCore

final class BandwidthSampleCodableTests: XCTestCase {

    private func decode(_ json: String) throws -> BandwidthSample {
        try JSONDecoder().decode(BandwidthSample.self, from: Data(json.utf8))
    }

    /// Oldest on-disk shape: four requestor doubles, no `measuredTotalGBs`, no `isEstimated`
    /// (every .ssrec recorded up to and including v3.2.0). Must decode, not throw `.keyNotFound`.
    func testDecodesPreIsEstimatedFrame() throws {
        let s = try decode(#"{"cpuGBs":1.5,"gpuGBs":2.5,"mediaGBs":0,"otherGBs":3}"#)
        XCTAssertEqual(s.cpuGBs, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.gpuGBs, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.otherGBs, 3, accuracy: 1e-9)
        XCTAssertNil(s.measuredTotalGBs)
        XCTAssertFalse(s.isEstimated, "a frame written before isEstimated existed must default it, not fail")
        XCTAssertEqual(s.totalGBs, 7, accuracy: 1e-9)
    }

    /// measuredTotalGBs-era shape (that field is optional and already backward-compatible), still
    /// with no `isEstimated`. Both the optional and the new non-optional field must be tolerated.
    func testDecodesMeasuredTotalEraFrame() throws {
        let s = try decode(#"{"cpuGBs":0,"gpuGBs":0,"mediaGBs":0,"otherGBs":0,"measuredTotalGBs":42}"#)
        XCTAssertEqual(s.measuredTotalGBs, 42)
        XCTAssertFalse(s.isEstimated)
        XCTAssertEqual(s.totalGBs, 42, accuracy: 1e-9, "measuredTotalGBs wins over the requestor sum")
    }

    /// Current shape (isEstimated present) must round-trip losslessly in both directions.
    func testRoundTripPreservesIsEstimated() throws {
        var s = BandwidthSample()
        s.cpuGBs = 4; s.gpuGBs = 1; s.isEstimated = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(BandwidthSample.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isEstimated)
    }

    /// An explicit isEstimated:true on disk still decodes as true (guards against a decoder that
    /// hard-codes false instead of honoring the stored value).
    func testDecodesExplicitEstimatedTrue() throws {
        let s = try decode(#"{"cpuGBs":0,"gpuGBs":0,"mediaGBs":0,"otherGBs":0,"isEstimated":true}"#)
        XCTAssertTrue(s.isEstimated)
    }
}
