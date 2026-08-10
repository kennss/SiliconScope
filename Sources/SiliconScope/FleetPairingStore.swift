//
//  File:      FleetPairingStore.swift
//  Created:   2026-07-22
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Per-machine Fleet security state. The bearer token (secret) lives in the Keychain; the
//             TOFU TLS cert fingerprint (public — just a hash) lives in UserDefaults. Both are keyed
//             by the machine's display name (mDNS instance name, or the label of a manually-added
//             off-LAN endpoint) and injected into the HTTPFleetSource on every (re)build, so
//             authenticated, encrypted, MITM-resistant polling survives across launches.
//  Notes:     Token: generic-password items under one service; account = mDNS instance name (display
//             label). Keychain APIs are thread-safe, so these are plain nonisolated statics.
//             Accessible AfterFirstUnlock so background polling works when the screen is locked.
//             Fingerprint: remembered on first connect (TOFU); a later mismatch means re-key/MITM.
//
import Foundation
import Security

enum FleetPairingStore {
    private static let service = "ai.calidalab.SiliconScope.fleet-token"

    // MARK: - TOFU cert fingerprint (public hash → UserDefaults)

    static func fingerprint(for name: String) -> String? {
        UserDefaults.standard.string(forKey: "ai.calidalab.SiliconScope.fleet-fp.\(name)")
    }

    static func setFingerprint(_ fingerprint: String, for name: String) {
        UserDefaults.standard.set(fingerprint, forKey: "ai.calidalab.SiliconScope.fleet-fp.\(name)")
    }

    static func removeFingerprint(for name: String) {
        UserDefaults.standard.removeObject(forKey: "ai.calidalab.SiliconScope.fleet-fp.\(name)")
    }

    // MARK: - Bearer token (secret → Keychain)

    /// Tokens already read this launch, so discovery does not re-enter the Keychain on every mDNS
    /// event.
    ///
    /// ⚠️ This is a HANG fix, not an optimisation. `FleetDiscovery` is `@MainActor` and calls this
    /// once per machine from `emit()`, which runs on every discovery change — so a synchronous
    /// `SecItemCopyMatching` sits on the main thread N times per event. Whenever securityd is slow,
    /// or shows an access prompt, the whole window freezes until it answers (observed twice, and
    /// the reason the app appeared to lock up on launch and on opening Fleet).
    ///
    /// Correctness: the cache is authoritative because every write goes through `setToken` /
    /// `removeToken` below, which update it. A token changed by another process would be missed —
    /// nothing else writes these items.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func token(for name: String) -> String? {
        cacheLock.lock()
        if let hit = cache[name] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = readTokenFromKeychain(name)
        cacheLock.lock(); cache[name] = value; cacheLock.unlock()
        return value
    }

    private static func readTokenFromKeychain(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func setToken(_ token: String, for name: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        cacheLock.lock(); cache[name] = token; cacheLock.unlock()
    }

    static func removeToken(for name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        cacheLock.lock(); cache[name] = String?.none; cacheLock.unlock()
    }
}
