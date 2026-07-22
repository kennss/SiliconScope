//
//  File:      FleetManualStore.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Persistence for MANUALLY-added fleet endpoints — machines the viewer can't auto-discover
//             because they aren't on the local subnet: a lab/office GPU box or a cloud instance reached
//             over Tailscale, a VPN, or an SSH tunnel (mDNS is link-local and doesn't traverse L3). Each
//             entry is just a host:port the aggregator connects to directly; the existing TLS TOFU pin +
//             bearer-token pairing layer on top, so a manual endpoint is exactly as secure as a
//             discovered one — only auto-discovery is skipped.
//  Notes:     Stored as a JSON array in UserDefaults (public host:port only — the token lives in the
//             Keychain via FleetPairingStore, keyed by `name`). `id` = "host:port" (dedup key); `name`
//             is the display label AND the pairing key, so keep it stable/unique per machine.
//             The pasted one-line handoff itself is `PairingLink` (Core), shared with the agents.
//
import Foundation

/// One manually-added agent endpoint (off-LAN: Tailscale / VPN / tunnel / cloud).
struct ManualEndpoint: Codable, Identifiable, Equatable {
    let name: String     // display label + pairing key (FleetPairingStore is keyed by this)
    let host: String     // IP, hostname, or Tailscale MagicDNS name
    let port: Int
    var id: String { "\(host):\(port)" }
}

enum FleetManualStore {
    private static let key = "ai.calidalab.SiliconScope.fleet-manual"

    static func all() -> [ManualEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ManualEndpoint].self, from: data) else { return [] }
        return list
    }

    /// Add (replacing any entry with the same host:port). Later entries win.
    static func add(_ e: ManualEndpoint) {
        save(all().filter { $0.id != e.id } + [e])
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    private static func save(_ list: [ManualEndpoint]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
