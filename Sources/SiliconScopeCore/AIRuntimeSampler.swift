//
//  File:      AIRuntimeSampler.swift
//  Created:   2026-06-14
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Turns the already-built process table into an AIRuntimeSample. Caches the
//             per-pid match verdict (a process's path/args are immutable for its lifetime),
//             so the ~15 substring probes in AIRuntimeKind.match run once per NEW process
//             instead of for every process on every scan — the repeated scan measured
//             ~30 ms across a few thousand rows (#28 investigation).
//  Notes:     Relies on ProcessSampler having resolved path (all pids) and args (AI
//             candidates only). Verdicts are keyed by pid and validated against the row's
//             path, so a recycled pid (same number, new process) re-matches correctly.
//             100% sudoless, no network.
//
import Foundation

public final class AIRuntimeSampler {
    /// Cached classification for one pid — including the "not an AI runtime" verdict
    /// (kind == nil), so non-AI processes also skip re-matching.
    private struct Verdict {
        let path: String
        let kind: AIRuntimeKind?
        let embeddedPort: Int?
    }
    private var verdicts: [pid_t: Verdict] = [:]

    public init() {}

    public func sample(from rows: [ProcessRow]) -> AIRuntimeSample {
        var sample = AIRuntimeSample()
        var live = Set<pid_t>(minimumCapacity: rows.count)
        for row in rows {
            live.insert(row.pid)
            let verdict: Verdict
            if let cached = verdicts[row.pid], cached.path == row.path {
                verdict = cached
            } else {
                let kind = AIRuntimeKind.match(path: row.path, name: row.name, args: row.args)
                verdict = Verdict(path: row.path,
                                  kind: kind,
                                  embeddedPort: kind != nil ? AIRuntimeKind.embeddedPort(args: row.args) : nil)
                verdicts[row.pid] = verdict
            }
            guard let kind = verdict.kind else { continue }
            sample.processes.append(AIRuntimeProcess(
                pid: row.pid,
                kind: kind,
                displayName: kind.displayName,
                cpuPercent: row.cpuPercent,
                memoryBytes: row.memoryBytes,
                embeddedPort: verdict.embeddedPort
            ))
        }
        // Prune dead pids so the cache tracks the live process set.
        verdicts = verdicts.filter { live.contains($0.key) }
        return sample
    }
}
