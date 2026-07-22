//
//  File:      PairingLinkTests.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the agent↔viewer pairing handoff. The installer PRINTS `PairingLink.url` and the
//             viewer PARSES the pasted text with `init?`, so encode/decode must round-trip exactly —
//             a drift here means a user pastes a link and gets "pairing required" anyway.
//  Notes:     The unicode case is the one that actually bit: a Mac's computer name routinely holds
//             spaces and Hangul, and an un-encoded name silently breaks the pairing KEY (the token is
//             stored under `name`), not just the display label.
//
import XCTest
@testable import SiliconScopeCore

final class PairingLinkTests: XCTestCase {

    /// Names with spaces + non-ASCII must survive the trip byte-for-byte, because `name` is the
    /// Keychain key the token is stored under.
    func testRoundTripsUnicodeName() throws {
        let original = PairingLink(name: "Yongsoo의 MacBook Air M1", host: "192.168.68.129",
                                   port: 7799, token: "z2VKicbsaDyj0_IPu_es8gUaV9EoQ-25NCiFaSaPYX0")
        let printed = original.url
        XCTAssertTrue(printed.hasPrefix("sscope://pair?"), printed)
        XCTAssertFalse(printed.contains(" "), "a printed link must be safely pasteable: \(printed)")

        let parsed = try XCTUnwrap(PairingLink(printed))
        XCTAssertEqual(parsed.name, original.name)      // exact key match, or pairing silently fails
        XCTAssertEqual(parsed.host, original.host)
        XCTAssertEqual(parsed.port, original.port)
        XCTAssertEqual(parsed.token, original.token)
    }

    /// Pasted text arrives with stray whitespace/newlines from terminal copy — that must still parse.
    func testParsesWithSurroundingWhitespace() throws {
        let raw = "\n   sscope://pair?name=kennt-Ubuntu&host=192.168.68.121&port=7799&token=abc123   \n"
        let link = try XCTUnwrap(PairingLink(raw))
        XCTAssertEqual(link.name, "kennt-Ubuntu")
        XCTAssertEqual(link.host, "192.168.68.121")
        XCTAssertEqual(link.token, "abc123")
    }

    /// A missing port falls back to the agent default rather than failing the paste.
    func testDefaultsPortWhenAbsent() throws {
        let link = try XCTUnwrap(PairingLink("sscope://pair?host=10.0.0.5&token=t"))
        XCTAssertEqual(link.port, 7799)
        XCTAssertEqual(link.name, "10.0.0.5")   // no name → fall back to the address
    }

    /// Plain hostnames and junk must NOT parse, so the sheet keeps treating them as a typed address.
    func testRejectsNonLinks() {
        XCTAssertNil(PairingLink("192.168.68.129"))
        XCTAssertNil(PairingLink("mybox.tailnet.ts.net"))
        XCTAssertNil(PairingLink("https://example.com/pair?host=h&token=t"))   // wrong scheme
        XCTAssertNil(PairingLink("sscope://other?host=h&token=t"))            // wrong action
        XCTAssertNil(PairingLink("sscope://pair?host=h"))                     // no token
        XCTAssertNil(PairingLink("sscope://pair?token=t"))                    // no host
        XCTAssertNil(PairingLink(""))
    }
}
