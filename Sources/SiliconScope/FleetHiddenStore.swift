//
//  File:      FleetHiddenStore.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Machines the user has removed from the Fleet list even though the network keeps
//             offering them. A manually-added endpoint can simply be deleted, but an mDNS-discovered
//             agent is found again the moment discovery runs — so "remove" for those has to mean
//             "remember that I do not want to see this", not "forget the address".
//  Notes:     Keyed by the mDNS instance name, the same key `FleetPairingStore` uses, so hiding a
//             machine and forgetting its token address the same thing.
//             ⚠️ Hiding must always be reversible. A live machine that vanishes with no way back
//             is a worse outcome than a list with one row too many, which is why `all()` is public
//             and the sidebar surfaces a restore affordance whenever this set is non-empty.
//
import Foundation

enum FleetHiddenStore {
    private static let key = "ai.calidalab.SiliconScope.fleet-hidden"

    /// Names the user has removed. Sorted so the restore UI has a stable order.
    static func all() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? []).sorted()
    }

    static func contains(_ name: String) -> Bool {
        Set(all()).contains(name)
    }

    static func hide(_ name: String) {
        var s = Set(all()); s.insert(name)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func unhide(_ name: String) {
        var s = Set(all()); s.remove(name)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func unhideAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
