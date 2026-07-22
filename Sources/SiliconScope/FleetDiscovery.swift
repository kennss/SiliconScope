//
//  File:      FleetDiscovery.swift
//  Created:   2026-07-21
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  mDNS/Bonjour auto-discovery of fleet agents on the LAN. Browses "_sscope-agent._tcp",
//             resolves each service to host:port, and hands FleetMonitor an https HTTPFleetSource
//             per machine — no hardcoded IP/port. Security is layered on top: the stored bearer token
//             and TOFU cert pin (keyed by instance name) are injected on every (re)build, and the
//             first-seen cert is remembered via the source's onObservedFingerprint callback.
//  Notes:     macOS 14+ gates local-network access behind a privacy prompt; the packaged app declares
//             NSLocalNetworkUsageDescription + NSBonjourServices (see package.sh). Resolution forces
//             IPv4 (see resolve()) because Bonjour otherwise yields a zone-less IPv6 link-local that
//             URLSession can't route. NWBrowser doesn't reliably deliver TXT, so we don't rely on it
//             — the cert pin is learned on first connect (TOFU) rather than read from a TXT record.
//
import Foundation
import Network
import SiliconScopeCore

@MainActor
final class FleetDiscovery {
    /// Raw discovery info for one agent, cached so sources can be rebuilt (after pairing / TOFU)
    /// without re-resolving. `name` is the mDNS instance name — display label AND security key.
    private struct DiscoveredAgent {
        let name: String
        let host: String
        let port: Int
    }

    private var browser: NWBrowser?
    private let onChange: ([any FleetSource]) -> Void
    private var cache: [String: DiscoveredAgent] = [:]   // instance name → agent
    /// This Mac's own Bonjour name — skipped in discovery since it's already listed as "This Mac"
    /// (when share mode is on, the local agent would otherwise self-discover as a duplicate).
    private static let localComputerName = Host.current().localizedName ?? ""

    init(onChange: @escaping ([any FleetSource]) -> Void) { self.onChange = onChange }

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_sscope-agent._tcp", domain: "local."), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in await self?.handle(results) }
        }
        // Surfaces local-network-permission denial: a build without the entitlement gets .waiting
        // with a policy error here instead of ever producing results.
        b.stateUpdateHandler = { state in
            switch state {
            case .failed(let e):  NSLog("[Fleet] browser failed: \(e)")
            case .waiting(let e): NSLog("[Fleet] browser waiting: \(e)")
            default: break
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Re-emit sources from the current cache, re-reading token + pin. Call after pairing/TOFU changes.
    func rebuild() { emit() }

    private func handle(_ results: Set<NWBrowser.Result>) async {
        var seen = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            if name == Self.localComputerName { continue }   // skip ourselves; This Mac is already listed
            seen.insert(name)
            if cache[name] != nil { continue }   // already resolved this instance
            if let (host, port) = await Self.resolve(r.endpoint) {
                cache[name] = DiscoveredAgent(name: name, host: host, port: port)
            }
        }
        // Drop instances that are no longer advertised.
        for key in cache.keys where !seen.contains(key) { cache.removeValue(forKey: key) }
        emit()
    }

    /// Build https FleetSources from cached agents, injecting the stored token + TOFU pin each time
    /// and wiring the first-connect callback that remembers the cert.
    private func emit() {
        let sources: [any FleetSource] = cache.values.compactMap { a in
            let hostForURL = a.host.contains(":") ? "[\(a.host)]" : a.host   // bracket IPv6
            guard let url = URL(string: "https://\(hostForURL):\(a.port)/metrics") else { return nil }
            let name = a.name
            return HTTPFleetSource(
                id: "mdns:\(name)", label: name, endpoint: url,
                token: FleetPairingStore.token(for: name),
                pinnedFingerprint: FleetPairingStore.fingerprint(for: name),
                onObservedFingerprint: { [weak self] fp in
                    Task { @MainActor in
                        FleetPairingStore.setFingerprint(fp, for: name)
                        self?.rebuild()   // re-emit so the pin is enforced from now on
                    }
                }
            )
        }
        onChange(sources)
    }

    /// Resolve a Bonjour service endpoint to a concrete host:port by briefly connecting to it
    /// (connecting forces resolution) and reading the resolved remote endpoint.
    private static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        // Force IPv4. Bonjour resolution otherwise tends to yield an IPv6 link-local address
        // (fe80::…) whose zone id (%enN) is absent from the resolved endpoint, so URLSession can't
        // route to it and fails immediately with ENETDOWN/-1009. Fleet machines on a LAN are always
        // reachable over IPv4, so pinning the address family gives a stable, connectable host.
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        let result: (String, Int)? = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }  // strip %interface zone
                        once.resume((h, Int(port.rawValue)))
                    } else {
                        once.resume(nil)
                    }
                case .failed, .cancelled:
                    once.resume(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
        conn.cancel()
        return result
    }

    /// Resumes a checked continuation at most once, safely across the connection's callback queue.
    private final class ResumeOnce: @unchecked Sendable {
        private var cont: CheckedContinuation<(String, Int)?, Never>?
        private let lock = NSLock()
        init(_ cont: CheckedContinuation<(String, Int)?, Never>) { self.cont = cont }
        func resume(_ value: (String, Int)?) {
            lock.lock(); defer { lock.unlock() }
            cont?.resume(returning: value)
            cont = nil
        }
    }
}
