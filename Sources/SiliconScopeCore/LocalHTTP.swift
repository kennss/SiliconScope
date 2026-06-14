//
//  File:      LocalHTTP.swift
//  Created:   2026-06-14
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Minimal localhost-only HTTP GET used by the opt-in runtime-API probes.
//             Targets the IP literal 127.0.0.1 (no DNS, no captive-portal/egress risk),
//             proxies and cellular disabled, hard per-request timeout, and an outer
//             timeout race so a hung socket can never stall the monitor loop.
//  Notes:     Nothing leaves the machine. Used only when the user enables the runtime API.
//
import Foundation

public struct LocalHTTP: Sendable {
    public enum HTTPError: Error { case badStatus(Int), timedOut, badURL }

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.8
        cfg.timeoutIntervalForResource = 1.5
        cfg.connectionProxyDictionary = [:]            // ignore system proxies
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = false
        session = URLSession(configuration: cfg)
    }

    /// GET http://127.0.0.1:<port><path>. Returns the body on 2xx; throws otherwise.
    public func get(port: Int, path: String) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw HTTPError.badURL }
        return try await withLocalTimeout(seconds: 1.2) {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { throw HTTPError.badStatus(code) }
            return data
        }
    }
}

/// Races an async operation against a wall-clock timeout (belt-and-suspenders over the
/// URLSession timeout). Cancels the loser.
public func withLocalTimeout<T: Sendable>(seconds: Double,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LocalHTTP.HTTPError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
