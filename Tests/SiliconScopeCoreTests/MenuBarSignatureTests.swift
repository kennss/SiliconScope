//
//  File:      MenuBarSignatureTests.swift
//  Created:   2026-07-14
//  Updated:   2026-07-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for the menu-bar glyph dedup signatures (FIX 3): a visible input change
//             MUST flip the signature (no stale glyph), while sub-pixel float jitter MUST NOT
//             (so an idle machine's stable bars actually dedupe — that's where the saving comes from).
//
import XCTest
@testable import SiliconScopeCore

final class MenuBarSignatureTests: XCTestCase {
    func testQuantizeClampsAndBounds() {
        XCTAssertEqual(MenuBarSignature.quantize(0.0), 0)
        XCTAssertEqual(MenuBarSignature.quantize(1.0), 36)
        XCTAssertEqual(MenuBarSignature.quantize(-0.5), 0)   // clamped low
        XCTAssertEqual(MenuBarSignature.quantize(1.9), 36)   // clamped high
    }

    func testQuantizeIgnoresSubPixelJitterButFlipsOnVisibleChange() {
        // One row ≈ 1/36 ≈ 0.028. A 0.005 jitter must not move the row; a 0.05 change must.
        XCTAssertEqual(MenuBarSignature.quantize(0.50), MenuBarSignature.quantize(0.505))
        XCTAssertNotEqual(MenuBarSignature.quantize(0.50), MenuBarSignature.quantize(0.55))
    }

    func testBarsDedupeJitterNotVisibleChange() {
        let base   = MenuBarSignature.bars("cpu", [0.50, 0.20], dark: false)
        let jitter = MenuBarSignature.bars("cpu", [0.505, 0.203], dark: false)
        let moved  = MenuBarSignature.bars("cpu", [0.60, 0.20], dark: false)
        XCTAssertEqual(base, jitter)      // sub-pixel jitter → same signature (dedup)
        XCTAssertNotEqual(base, moved)    // a bar visibly moved → different signature
    }

    func testAppearanceAndExtraFlipSignature() {
        XCTAssertNotEqual(MenuBarSignature.bars("cpu", [0.5], dark: false),
                          MenuBarSignature.bars("cpu", [0.5], dark: true))       // light vs dark
        XCTAssertNotEqual(MenuBarSignature.bars("ss", [0.5], dark: false, extra: "a0"),
                          MenuBarSignature.bars("ss", [0.5], dark: false, extra: "a1"))  // blink parity
    }

    func testTextSignature() {
        XCTAssertEqual(MenuBarSignature.text("mem", ["12.3 GB", "4.5 GB"], dark: false),
                       MenuBarSignature.text("mem", ["12.3 GB", "4.5 GB"], dark: false))
        XCTAssertNotEqual(MenuBarSignature.text("mem", ["12.3 GB", "4.5 GB"], dark: false),
                          MenuBarSignature.text("mem", ["12.4 GB", "4.5 GB"], dark: false))
    }
}
