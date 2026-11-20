//
//  File:      ProcessGrouping.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Folds the process table into apps: every process whose executable lives inside an
//             `.app` bundle joins the row of the OUTERMOST bundle on its path, so Chrome's renderer,
//             GPU and utility helpers read as one "Google Chrome" row instead of filling the top of
//             the list. Processes outside any bundle (daemons, CLI tools, VMs) keep a row each.
//  Notes:     Grouping is read from the executable path libproc reports, never guessed from a name:
//             two apps that share a name in different places stay apart (the key is the bundle's
//             full path), and a process whose path was denied ("") stands alone.
//             cpuPercent sums exactly (CPU time is additive). memoryBytes is a sum of each member's
//             resident size, which counts pages the members share once per member, so it reads
//             high; the UI must say "sum" rather than present it as the app's footprint.
//
import Foundation

/// One row of the process table folded by app.
public struct ProcessAppGroup: Sendable, Equatable, Identifiable {
    /// The bundle's full path for an app, or "pid:<n>" for a process outside any bundle.
    public let id: String
    /// The app's name (bundle name without `.app`), or the process's own name.
    public let name: String
    /// Summed across members, top-style (can exceed 100).
    public let cpuPercent: Double
    /// Sum of the members' resident sizes — see the file notes.
    public let memoryBytes: UInt64
    /// Members, busiest first.
    public let members: [ProcessRow]

    public var count: Int { members.count }
    /// True for a lone process outside any bundle; such a row is exactly one process.
    public var isSingleProcess: Bool { id.hasPrefix("pid:") }
}

public enum ProcessGrouping {
    /// The outermost `.app` bundle on an executable path: its full path and display name.
    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper (Renderer).app/…`
    /// → (`/Applications/Google Chrome.app`, `Google Chrome`). nil when no component is a bundle.
    public static func outermostApp(path: String) -> (path: String, name: String)? {
        guard !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        let bundlePath = parts[...i].joined(separator: "/")
        return (bundlePath, String(parts[i].dropLast(4)))
    }

    /// Folds `rows` by app, busiest group first (ties broken by name, so the order is stable).
    public static func groups(_ rows: [ProcessRow]) -> [ProcessAppGroup] {
        var order: [String] = []
        var byKey: [String: (name: String, members: [ProcessRow])] = [:]
        for row in rows {
            let key: String
            let name: String
            if let app = outermostApp(path: row.path) {
                key = app.path; name = app.name
            } else {
                key = "pid:\(row.pid)"; name = row.name
            }
            if byKey[key] == nil { order.append(key); byKey[key] = (name, []) }
            byKey[key]!.members.append(row)
        }
        return order.compactMap { key -> ProcessAppGroup? in
            guard let g = byKey[key] else { return nil }
            let members = g.members.sorted { $0.cpuPercent > $1.cpuPercent }
            return ProcessAppGroup(id: key, name: g.name,
                                   cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                                   memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
                                   members: members)
        }
        .sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.name < $1.name }
    }
}
