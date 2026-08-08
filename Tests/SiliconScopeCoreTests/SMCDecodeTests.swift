//
//  File:      SMCDecodeTests.swift
//  Created:   2026-08-08
//  Updated:   2026-08-08
//  Developer: Yurii Chukhlib
//  Overview:  Unit tests for SMCReader.decode(type:bytes:) — the pure scalar decode extracted
//             from the hardware-coupled reader. Pins the fpe2 fixed-point value at FULL precision
//             (the bug: the old `(b0 << 6) + (b1 >> 2)` shift discarded the low 2 bits, flooring
//             every fpe2 power/current/voltage key to a whole number) and locks the other scalar
//             types (flt/ui8/ui16/ui32) so the extraction is a behaviour-preserving refactor.
//  Notes:     fpe2 is Apple SMC's 16-bit big-endian fixed-point with 2 fractional bits: the true
//             value is raw_uint16 / 4. No hardware: decode is a static fn over explicit byte arrays,
//             so the fractional cases that the old shift lost are pinned here deterministically.
//
import XCTest
@testable import SiliconScopeCore

final class SMCDecodeTests: XCTestCase {

    // MARK: - fpe2: 16-bit big-endian fixed-point, 2 fractional bits (value = raw uint16 / 4)

    /// The headline regression: bytes [0x00, 0x33] = raw 51 must decode to 12.75, not 12.0.
    /// The old `(Int(b0) << 6) + (Int(b1) >> 2)` returned 12.0 — it shifted away the .75.
    func testFpe2KeepsTheFraction() {
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x33]), 12.75)
    }

    /// Every fractional step a 2-bit fixed-point can express must survive the decode.
    func testFpe2QuarterSteps() {
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x01]), 0.25)
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x02]), 0.50)
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x03]), 0.75)
    }

    /// Boundaries of the fixed-point: raw 0 → 0.0, raw 4 → 1.0 (the smallest whole step).
    func testFpe2Boundaries() {
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x00]), 0.0)
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x00, 0x04]), 1.0)
    }

    /// Big-endian high byte carries weight: [0x01, 0x00] = raw 256 → 64.0 (a whole value, so it
    /// also confirms the extraction did not regress the high-byte path the old formula shared).
    func testFpe2BigEndianHighByte() {
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0x01, 0x00]), 64.0)
    }

    /// Full-scale: raw 0xFFFF (65535) → 16383.75 (the .75 is exactly what the old shift dropped).
    func testFpe2FullScale() {
        XCTAssertEqual(SMCReader.decode(type: "fpe2", bytes: [0xFF, 0xFF]), 16383.75)
    }

    /// The `bytes.count >= 2` guard: a short buffer returns nil rather than trapping.
    /// Defensive — `readDouble` always supplies the key's full byte width — but `decode` is now a
    /// directly-callable static fn, so its own contract must be crash-free on bad input.
    func testFpe2RejectsShortBuffer() {
        XCTAssertNil(SMCReader.decode(type: "fpe2", bytes: []))
        XCTAssertNil(SMCReader.decode(type: "fpe2", bytes: [0x00]))
    }

    // MARK: - Other scalar types: the extraction must be a behaviour-preserving refactor

    func testUi8() {
        XCTAssertEqual(SMCReader.decode(type: "ui8 ", bytes: [0x2A]), 42.0)
    }

    /// [0x01, 0x2C] = 300 (big-endian).
    func testUi16BigEndian() {
        XCTAssertEqual(SMCReader.decode(type: "ui16", bytes: [0x01, 0x2C]), 300.0)
    }

    /// [0x00, 0x01, 0x86, 0x9F] = 99999 (big-endian).
    func testUi32BigEndian() {
        XCTAssertEqual(SMCReader.decode(type: "ui32", bytes: [0x00, 0x01, 0x86, 0x9F]), 99999.0)
    }

    /// flt is a native-endian IEEE-754 load; build the bytes in the platform's own byte order so
    /// the test is self-consistent with how decode's loadUnaligned reads them, regardless of endian.
    func testFlt() throws {
        var bits: UInt32 = 0x4048F5C3   // float bits for 3.14
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        let value = try XCTUnwrap(SMCReader.decode(type: "flt ", bytes: bytes))
        XCTAssertEqual(value, 3.14, accuracy: 1e-6)
    }

    /// An unknown type falls through to nil (the default arm), never a crash.
    func testUnknownTypeReturnsNil() {
        XCTAssertNil(SMCReader.decode(type: "ch8*", bytes: [0x41, 0x42]))
    }
}
