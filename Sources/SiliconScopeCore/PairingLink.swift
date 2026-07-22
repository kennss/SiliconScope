//
//  File:      PairingLink.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The one-line handoff between an agent and the viewer:
//             `sscope://pair?name=…&host=…&port=7799&token=…`. An installer prints it (the agent
//             ENCODES via `url`), the user pastes it into "Add machine…" (the viewer DECODES via
//             `init?`), and the machine is added AND paired in a single copy — instead of
//             hand-carrying a 43-char token, hunting for the machine in the list, and pasting.
//  Notes:     Both directions live here on purpose, so the printed format and the parsed format can
//             never drift apart. `name` is the agent's mDNS instance name and doubles as the pairing
//             key (FleetPairingStore is keyed by it), so a machine already discovered on the LAN
//             pairs in place rather than appearing twice. Percent-encoding matters: a Mac's computer
//             name routinely contains spaces and non-ASCII. The token is a secret — treat a pairing
//             link like a password (it grants read access to that machine's metrics).
//
import Foundation

public struct PairingLink: Sendable, Equatable {
    public let name: String     // agent's mDNS instance name — also the pairing key
    public let host: String     // IP, hostname, or Tailscale/MagicDNS name
    public let port: Int
    public let token: String    // bearer token — secret

    public init(name: String, host: String, port: Int, token: String) {
        self.name = name; self.host = host; self.port = port; self.token = token
    }

    /// Decode a pasted link. nil when the text isn't one, so a plain hostname still works.
    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: text),
              c.scheme?.lowercased() == "sscope", c.host?.lowercased() == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where !(item.value ?? "").isEmpty { q[item.name] = item.value }
        guard let h = q["host"], let t = q["token"] else { return nil }
        host = h
        token = t
        port = Int(q["port"] ?? "") ?? 7799
        name = q["name"] ?? h
    }

    /// Encode for an installer to print. URLComponents handles the percent-encoding.
    public var url: String {
        var c = URLComponents()
        c.scheme = "sscope"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
        ]
        return c.url?.absoluteString ?? ""
    }
}
