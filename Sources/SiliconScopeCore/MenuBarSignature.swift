//
//  File:      MenuBarSignature.swift
//  Created:   2026-07-14
//  Updated:   2026-07-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Cheap value signatures for the menu-bar glyphs, used to skip re-rasterizing a
//             status-item bitmap that would come out pixel-identical. MetricBarController.sync
//             re-drew every glyph every tick (an always-on cost even with the dashboard closed);
//             now it only re-draws when the signature changes. See docs/energy-optimization.md FIX 3.
//  Notes:     Pure Foundation (no UI) so it lives in Core and is unit-tested. `quantize` maps a
//             0...1 bar fraction to the glyph's pixel-row resolution (bars are 18 pt ≈ 36 px tall
//             on a 2x display), so sub-pixel float jitter does NOT churn the signature, but any
//             visible (≥ one pixel row) change does. Text glyphs sign their already-formatted
//             strings (the string IS the visible quantization).
//
import Foundation

public enum MenuBarSignature {
    /// Bar glyph height is 18 pt ≈ 36 px on a 2x display; quantize to that many rows so a change
    /// smaller than one pixel row rounds to the same value (dedup) and a visible change flips it.
    static let barRows = 36

    /// 0...1 fraction → the pixel row a bar reaches (clamped). Sub-1/36 jitter rounds to the same row.
    public static func quantize(_ frac: Double) -> Int {
        Int((min(1, max(0, frac)) * Double(barRows)).rounded())
    }

    /// Signature for a bar glyph (SS / CPU / GPU): quantized bar heights + appearance. `extra`
    /// carries any non-bar state that changes the pixels (e.g. the SS glyph's alert/blink color).
    public static func bars(_ id: String, _ fracs: [Double], dark: Bool, extra: String = "") -> String {
        id + "|" + fracs.map { String(quantize($0)) }.joined(separator: ",") + "|" + extra + (dark ? "d" : "l")
    }

    /// Signature for a text glyph (MEM / NET / SSD / SEN / battery): the drawn strings + appearance.
    /// Identical formatted strings ⇒ identical pixels, so the strings are the signature.
    public static func text(_ id: String, _ parts: [String], dark: Bool) -> String {
        id + "|" + parts.joined(separator: "\u{1}") + "|" + (dark ? "d" : "l")
    }
}
