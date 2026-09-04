//
//  File:      FleetNicknameStore.swift
//  Created:   2026-09-05
//  Updated:   2026-09-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  A user-chosen display name for a fleet machine. Purely a presentation layer: the
//             nickname is stored ALONGSIDE the machine's identity, never in place of it, so naming
//             a box cannot disturb what the box is.
//  Notes:     ⚠️ Keyed by the machine's pairing key — the same string `FleetPairingStore` keys its
//             Keychain token and TOFU fingerprint by (the mDNS instance name, or a manual entry's
//             name). That is deliberate: rename must not touch identity. `ManualEndpoint.name` is
//             documented as "display label + pairing key", so had the rename edited that field
//             instead, a renamed machine would have lost its token and its pinned certificate and
//             come back as unpaired, re-asking for TOFU (#55).
//             Nicknames are viewer-side and per-user: they live in this Mac's UserDefaults and are
//             never sent to the agent, which keeps reporting its own hostname.
//
import Foundation

enum FleetNicknameStore {
    private static let prefix = "ai.calidalab.SiliconScope.fleet-nickname."

    /// The name this viewer gave the machine, or nil when it has none.
    static func nickname(for key: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sets the nickname, or clears it when `name` is nil or blank — so emptying the field in the
    /// rename box restores the machine's own reported name rather than leaving it blank.
    static func setNickname(_ name: String?, for key: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: prefix + key)
        }
    }

    /// Resolves what a machine should be called, most specific first.
    ///
    /// ⚠️ The order matters and is the fix for "the list order seems random" (#55): every view
    /// showed `hostname` while the list SORTED on `label` (the mDNS instance name), which is a
    /// different string — a Mac advertising "Mark's Mac mini" reports the hostname "mark-mini".
    /// Sorting by a value the user cannot see is indistinguishable from not sorting at all. One
    /// resolved name now feeds both, so the order is always the order of what is on screen.
    static func displayName(nicknameKey: String, hostname: String?) -> String {
        nickname(for: nicknameKey) ?? hostname ?? nicknameKey
    }
}
