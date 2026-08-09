//
//  File:      IOReportNaming.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  How IOReport spells the names this project matches on. Apple prefixes group and
//             channel names with a die/chip-id token on some OS versions and some parts — the
//             bandwidth group's "ECPU" became "DIE0 ECPU0" on a macOS 27 beta (#14), and a
//             reporter saw "PRIM MCPU0 DCS" on M5 Max (#30). A sampler that matches the bare
//             name reads 0 on those machines while every other panel keeps working.
//  Notes:     Two shapes, both anchored so an unrelated substring cannot match:
//             - `isUnit`      — the whole unit name ("CPU Energy", "GPU Energy", PMP's "ECPU")
//             - `hasUnitPrefix` — a unit family whose members carry numeric suffixes
//               ("GPU0", "ANE1", "EACC_CPU"), so new core/cluster counts need no code change.
//             Both accept the bare name OR the name preceded by ONE space-separated token, which
//             is the only shape Apple has used. This deliberately does NOT try to recognise which
//             tokens are die ids: enumerating them would be guessing at names we have never seen,
//             and the anchor (a leading space) is what makes the match safe without that guess.
//
import Foundation

/// Name-matching rules shared by every IOReport sampler.
public enum IOReportNaming {

    /// True when `name` is exactly `unit`, or is `unit` preceded by a chip-id/die token.
    /// `isUnit("DIE0 CPU Energy", "CPU Energy")` → true; `isUnit("GPU Energy", "CPU Energy")` → false.
    public static func isUnit(_ name: String, _ unit: String) -> Bool {
        name == unit || name.hasSuffix(" " + unit)
    }

    /// True when `name` begins with `unitPrefix`, or carries it immediately after a chip-id/die
    /// token. `hasUnitPrefix("DIE0 GPU0", "GPU")` → true; `hasUnitPrefix("AGPU", "GPU")` → false
    /// (no separator, so it is a different unit, not a prefixed one).
    public static func hasUnitPrefix(_ name: String, _ unitPrefix: String) -> Bool {
        name.hasPrefix(unitPrefix) || name.range(of: " " + unitPrefix) != nil
    }

    /// The trailing space-separated token — the unit itself, with any leading chip-id token
    /// dropped. `unitToken("DIE0 MCPU0")` → "MCPU0". Used where a rule inspects the unit's own
    /// spelling (a numeric cluster suffix) rather than testing for a known prefix.
    ///
    /// ⚠️ Only for single-token units. A unit whose own name contains a space ("CPU Energy",
    /// "GPU SRAM") would be cut in half — use `isUnit` for those.
    public static func unitToken(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }
}
