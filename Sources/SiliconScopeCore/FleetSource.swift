//
//  File:      FleetSource.swift
//  Created:   2026-07-21
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Transports behind the source-agnostic MachineMetrics boundary. `FleetSource` is the
//             protocol the aggregator/UI depend on; concrete transports are interchangeable:
//             `HTTPFleetSource` (the agent serving GET /metrics — the direct path), and
//             `SSHFleetSource` (interim: runs the one-shot agent over SSH, for boxes without the
//             serving agent yet / power users). A future mDNS-discovered, paired, encrypted
//             agent-push source will conform to the same protocol without touching FleetMonitor
//             or FleetView. UI-independent (Core): Foundation only.
//  Notes:     fetch() is async. HTTPS uses URLSession with a TOFU cert pin (SHA-256 of the leaf DER,
//             from the agent's mDNS TXT) + a Bearer token; SSH wraps a blocking Process on a detached
//             task so it never stalls the caller. Errors are surfaced as short strings for the row;
//             `.unauthorized` (HTTP 401) is distinct so the UI can prompt for pairing.
//
import Foundation
import CryptoKit
import Security

/// One remote machine, one transport. The aggregator/UI depend only on this.
public protocol FleetSource: Sendable {
    var id: String { get }
    var label: String { get }
    func fetch() async throws -> MachineMetrics
}

public enum FleetFetchError: Error, CustomStringConvertible {
    case httpFailed(String)
    case sshFailed(String)
    case noOutput
    case decodeFailed(String)
    case unauthorized       // HTTP 401 — token missing/wrong; UI should prompt to pair
    case certMismatch       // served TLS cert didn't match the pinned fingerprint (possible MITM)

    public var description: String {
        switch self {
        case .httpFailed(let s):   return "http: \(s)"
        case .sshFailed(let s):    return "ssh: \(s)"
        case .noOutput:            return "agent produced no output"
        case .decodeFailed(let s): return "decode: \(s)"
        case .unauthorized:        return "unauthorized — pairing required"
        case .certMismatch:        return "certificate mismatch — refusing to connect"
        }
    }
}

// MARK: - HTTP (agent serving GET /metrics — the direct transport)

public struct HTTPFleetSource: FleetSource {
    public let id: String
    public let label: String
    public let endpoint: URL
    public let token: String?             // Bearer token; nil = unpaired (agent then returns 401)
    public let pinnedFingerprint: String? // SHA-256 hex of the leaf cert DER; nil = trust-on-first-use
    public let onObservedFingerprint: (@Sendable (String) -> Void)?  // TOFU: report the first cert seen

    public init(id: String, label: String, endpoint: URL,
                token: String? = nil, pinnedFingerprint: String? = nil,
                onObservedFingerprint: (@Sendable (String) -> Void)? = nil) {
        self.id = id; self.label = label; self.endpoint = endpoint
        self.token = token; self.pinnedFingerprint = pinnedFingerprint
        self.onObservedFingerprint = onObservedFingerprint
    }

    public func fetch() async throws -> MachineMetrics {
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        // HTTPS: pin the agent's self-signed cert (default trust would reject it). If we already have
        // a pin, enforce it; otherwise trust the first cert and report it upward (TOFU). Plain HTTP
        // uses the shared session (used only in dev/tests; production agents are always TLS).
        let session: URLSession
        if endpoint.scheme == "https" {
            session = URLSession(configuration: .ephemeral,
                                 delegate: PinnedCertDelegate(pinned: pinnedFingerprint,
                                                              onObserved: onObservedFingerprint),
                                 delegateQueue: nil)
        } else {
            session = URLSession(configuration: .ephemeral)
        }
        defer { session.finishTasksAndInvalidate() }

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // A pin mismatch cancels the challenge, surfacing as a cancelled/SSL error.
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain &&
                (ns.code == NSURLErrorServerCertificateUntrusted || ns.code == NSURLErrorCancelled) {
                throw FleetFetchError.certMismatch
            }
            throw FleetFetchError.httpFailed(String(describing: error))
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw FleetFetchError.unauthorized }
            if http.statusCode != 200 { throw FleetFetchError.httpFailed("HTTP \(http.statusCode)") }
        }
        do {
            return try JSONDecoder().decode(MachineMetrics.self, from: data)
        } catch {
            throw FleetFetchError.decodeFailed(String(describing: error))
        }
    }
}

/// URLSession delegate implementing TOFU pinning of the agent's self-signed cert (default TLS trust
/// can't validate it). With a stored pin it trusts exactly that leaf (SHA-256 of DER) and rejects
/// anything else (re-key / MITM); without one it trusts the first cert and reports it so the caller
/// can remember it. Either way the channel is encrypted; the bearer token is the real authentication.
final class PinnedCertDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinned: String?
    private let onObserved: (@Sendable (String) -> Void)?

    init(pinned: String?, onObserved: (@Sendable (String) -> Void)?) {
        self.pinned = pinned?.lowercased(); self.onObserved = onObserved
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }

        let der = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if let pinned {
            if hash == pinned {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)  // re-keyed / MITM
            }
        } else {
            onObserved?(hash)  // TOFU: trust this first cert and remember it
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

// MARK: - SSH-pull (interim: one-shot agent over SSH)

public struct FleetMachineConfig: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let sshHost: String
    public let sshUser: String
    public let identityFile: String  // e.g. "~/.ssh/id_rsa"
    public let agentPath: String     // e.g. "/tmp/sscope-agent"

    public init(id: String, label: String, sshHost: String, sshUser: String,
                identityFile: String, agentPath: String) {
        self.id = id; self.label = label; self.sshHost = sshHost; self.sshUser = sshUser
        self.identityFile = identityFile; self.agentPath = agentPath
    }
}

public struct SSHFleetSource: FleetSource {
    public let config: FleetMachineConfig
    public var id: String { config.id }
    public var label: String { config.label }
    public init(config: FleetMachineConfig) { self.config = config }

    public func fetch() async throws -> MachineMetrics {
        let config = self.config
        return try await Task.detached(priority: .utility) {
            try SSHFleetSource.pull(config)
        }.value
    }

    private static func pull(_ config: FleetMachineConfig) throws -> MachineMetrics {
        let data = try runSSH(config)
        do {
            return try JSONDecoder().decode(MachineMetrics.self, from: data)
        } catch {
            throw FleetFetchError.decodeFailed(String(describing: error))
        }
    }

    private static func runSSH(_ config: FleetMachineConfig) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new",
            "-i", (config.identityFile as NSString).expandingTildeInPath,
            "\(config.sshUser)@\(config.sshHost)",
            config.agentPath,
        ]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FleetFetchError.sshFailed(msg?.isEmpty == false ? msg! : "exit \(p.terminationStatus)")
        }
        guard !out.isEmpty else { throw FleetFetchError.noOutput }
        return out
    }
}
