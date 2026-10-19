//
//  File:      FleetTrafficTests.swift
//  Created:   2026-10-05
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  #71: a viewer polling every 3 s cost ~11 KB a poll — a TLS handshake each time and an
//             uncompressed body. Pins the two Core pieces of the fix: the gzip member the Mac agent
//             sends (checked against the system's own gunzip), and the session pool that keeps one
//             connection per agent instead of one per poll — and that closing the pool never
//             invalidates a session a fetch has checked out (that aborted the app).
//
import XCTest
@testable import SiliconScopeCore

final class FleetTrafficTests: XCTestCase {

    // MARK: - gzip

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    /// The real proof: what we emit is what `gunzip` (and so URLSession) reads back.
    func testGzipRoundTripsThroughSystemGunzip() throws {
        for input in [Data(), Data("x".utf8), Data(String(repeating: "{\"cpu\":12.5},", count: 600).utf8)] {
            let gz = try XCTUnwrap(Gzip.encode(input))
            XCTAssertEqual(Array(gz.prefix(2)), [0x1f, 0x8b])
            XCTAssertEqual(try gunzip(gz), input)
        }
    }

    func testMetricsSizedJSONShrinks() throws {
        let json = Data((0..<120).map { "{\"name\":\"core\($0)\",\"usage\":\(Double($0) / 7)}" }
                            .joined(separator: ",").utf8)
        let gz = try XCTUnwrap(Gzip.encode(json))
        XCTAssertLessThan(gz.count, json.count / 3, "\(json.count) → \(gz.count) bytes")
    }

    func testAcceptEncodingParsing() {
        XCTAssertTrue(Gzip.accepted(byAcceptEncoding: "gzip, deflate, br"))
        XCTAssertTrue(Gzip.accepted(byAcceptEncoding: "br;q=1.0, GZIP;q=0.8"))
        XCTAssertTrue(Gzip.accepted(byAcceptEncoding: "*"))
        XCTAssertFalse(Gzip.accepted(byAcceptEncoding: nil))
        XCTAssertFalse(Gzip.accepted(byAcceptEncoding: "deflate"))
        XCTAssertFalse(Gzip.accepted(byAcceptEncoding: "gzip;q=0"))
    }

    // MARK: - Session pool

    private func source(_ host: String, pin: String?) -> HTTPFleetSource {
        HTTPFleetSource(id: host, label: host, endpoint: URL(string: "https://\(host):7799/metrics")!,
                        token: "t", pinnedFingerprint: pin)
    }

    func testOneSessionPerAgentIsReusedAcrossPolls() {
        let pool = FleetSessionPool()
        let a = source("10.0.0.1", pin: "AA")
        XCTAssertTrue(pool.session(for: a) === pool.session(for: a))
        // The same agent rebuilt as a new value (discovery refresh) is still the same connection.
        XCTAssertTrue(pool.session(for: a) === pool.session(for: source("10.0.0.1", pin: "aa")))
        XCTAssertFalse(pool.session(for: a) === pool.session(for: source("10.0.0.2", pin: "AA")))
        pool.closeAll()
    }

    /// TOFU: the trusting session must not outlive the pin it learned.
    func testLearningAPinGetsAnEnforcingSession() {
        let pool = FleetSessionPool()
        let trusting = pool.session(for: source("10.0.0.1", pin: nil))
        XCTAssertFalse(trusting === pool.session(for: source("10.0.0.1", pin: "AA")))
        pool.retainOnly([source("10.0.0.1", pin: "AA")])
        XCTAssertEqual(pool.count, 1)
        pool.closeAll()
        XCTAssertEqual(pool.count, 0)
    }

    /// Closing the pool mid-fetch must not invalidate the session the fetch is about to use:
    /// a task created on an invalidated session throws an Objective-C exception and aborts the app.
    func testClosingThePoolWaitsForACheckedOutSession() async throws {
        let pool = FleetSessionPool()
        let a = source("127.0.0.1", pin: "AA")
        let session = pool.checkOut(for: a)
        pool.closeAll()
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(pool.retiredCount, 1)
        // Still usable: this would abort the test process if the session had been invalidated.
        var req = URLRequest(url: URL(string: "http://127.0.0.1:9/")!)
        req.timeoutInterval = 1
        _ = try? await session.data(for: req)
        pool.checkIn(session)
        XCTAssertEqual(pool.retiredCount, 0)
        // A later fetch gets a new session, not the closed one.
        let next = pool.checkOut(for: a)
        XCTAssertFalse(next === session)
        pool.checkIn(next)
        pool.closeAll()
    }

    func testRetainOnlyWaitsForACheckedOutSession() {
        let pool = FleetSessionPool()
        let trusting = pool.checkOut(for: source("10.0.0.1", pin: nil))
        pool.retainOnly([source("10.0.0.1", pin: "AA")])
        XCTAssertEqual(pool.retiredCount, 1)
        pool.checkIn(trusting)
        XCTAssertEqual(pool.retiredCount, 0)
        pool.closeAll()
    }

    private func gunzip(_ data: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "gunzip rejected the stream")
        return out
    }
}
