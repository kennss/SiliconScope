//
//  File:      ProcessSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-10-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Builds the process table sudolessly via libproc. Stateful: each
//             sample() diffs cumulative CPU time against the previous call to derive
//             CPU%. Memory is resident size (RSS). Also resolves each pid's executable
//             path (proc_pidpath) and, for AI-runtime candidates only, its argv
//             (KERN_PROCARGS2) — the plumbing AIRuntimeSampler builds on. Other users'
//             processes stay out of the table; the few that may be AI runtimes are read
//             through /bin/ps for AI detection only (ProcessTable.otherUsers, #85).
//  Notes:     proc_pidinfo(PROC_PIDTASKINFO) gives total_user+total_system (ns) and
//             resident_size. Prime with one sample(), wait, then sample() again for
//             meaningful CPU%. proc_pidpath across ~1k pids is ~7 ms (measured) — cheap.
//             argv is read only for a small candidate shortlist so KERN_PROCARGS2 never
//             runs per-pid.
//             ⚠️ Without root, libproc tells one user only the executable PATH of another
//             user's process: proc_name, PROC_PIDTASKINFO, PROC_PIDTBSDINFO and the fd list
//             answer EPERM and KERN_PROCARGS2 EINVAL (measured on macOS 27 against root,
//             _mdnsresponder and _locationd processes, 2026-10-22). /bin/ps is setuid root and
//             reads their memory, CPU time and argv, so it fills in the candidates — and runs
//             only on a sample that has one, which most Macs never do.
//
import Foundation

/// One pass over the process list.
public struct ProcessTable: Sendable, Equatable {
    /// This user's processes, sorted by CPU% (descending): the Processes card's rows, which it can
    /// inspect and signal.
    public var rows: [ProcessRow]
    /// Other users' processes that may be AI runtimes (their path names one, or is an interpreter or
    /// launcher a runtime runs as), read through /bin/ps. Only AI detection reads them: without root
    /// they can be neither inspected nor signalled, so they stay out of the table.
    ///
    /// ⚠️ Before these, a runtime run by a separate account (a sandboxed "ai" user serving Ollama
    /// and oMLX to the login user) was invisible: the table skipped every process it could not read,
    /// detection never saw the runtime, and the API was never asked although the user had set its
    /// port and could reach it (#85).
    public var otherUsers: [ProcessRow]

    public init(rows: [ProcessRow] = [], otherUsers: [ProcessRow] = []) {
        self.rows = rows
        self.otherUsers = otherUsers
    }

    /// Every row AI detection looks at.
    public var forAIDetection: [ProcessRow] { rows + otherUsers }
}

public final class ProcessSampler {
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTimeNs: UInt64 = 0

    // Immutable per-pid metadata (executable path, name, basename) cached across ticks — these
    // never change for a process's lifetime, so re-resolving them every tick via proc_pidpath /
    // proc_name over thousands of pids was the enumeration's dominant cost (proc_pidpath alone is
    // ~24 ms/tick at ~3.4k pids). Only NEW pids pay the lookup; existing ones just re-read CPU.
    // Other users' pids are cached too, with whether they may be an AI runtime, so their lookup and
    // that judgement (~15 substring probes, AIRuntimeKind.match) run once per pid, not every tick.
    private struct PidInfo {
        let path: String
        let name: String
        let base: String
        var aiCandidate = false   // other users' processes only: mayBeAIRuntime(path:)
    }
    private var infoCache: [pid_t: PidInfo] = [:]

    /// proc_taskinfo's pti_total_user/system are mach-absolute-time ticks, NOT nanoseconds.
    /// On Apple Silicon the timebase is 125/3, so a raw tick count read as ns makes CPU%
    /// come out ~42x too low. Convert ticks → ns with this factor (identity on Intel).
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// Path basenames worth reading argv for (AI-runtime candidates only). Keeps the
    /// gated KERN_PROCARGS2 read off the hot path for the ~1k unrelated processes.
    private static let argvCandidateBasenames: Set<String> = [
        "llama-server", "llama-cli", "lms", "ollama",
        "ds4-server",   // its `--port N` is where the API answers
        "mtplx",        // a launcher run directly: `serve`/`start` is what makes it a server
    ]

    /// Whether argv is worth reading for a process with this basename. Any Python interpreter
    /// qualifies, since a Python runtime (mlx_lm, oMLX, vLLM, MTPLX …) is told apart only by its
    /// argv. Matched without case: Homebrew's, python.org's and Xcode's Python are framework builds,
    /// which re-exec as `…/Python.app/Contents/MacOS/Python`, so a venv's `bin/python3.12` runs
    /// with the basename "Python" (#85). Versioned names (python3.12, python3.13t) pass the prefix.
    private static func wantsArgs(base: String) -> Bool {
        argvCandidateBasenames.contains(base) || base.lowercased().hasPrefix("python")
    }

    /// Whether another user's process may be an AI runtime, judged from the only thing libproc
    /// gives for it: its executable path. True when the path alone names a runtime (a bundle, a
    /// support directory, a runtime's own binary) or names a program whose argv decides it.
    static func mayBeAIRuntime(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let base = basename(path)
        return wantsArgs(base: base) || AIRuntimeKind.match(path: path, name: base, args: nil) != nil
    }

    public init() {}

    /// This user's processes sorted by CPU% (descending), capped at `count` (default: all, so the
    /// UI can re-sort/filter the full set), and other users' AI-runtime candidates.
    public func sample(top count: Int = .max) -> ProcessTable {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let wallDelta = previousTimeNs > 0 ? Double(nowNs &- previousTimeNs) : 0

        var currentCPU: [pid_t: UInt64] = [:]
        var rows: [ProcessRow] = []
        var listed = Set<pid_t>()
        var candidates: [pid_t] = []

        for pid in Self.allPIDs() where pid > 0 {
            listed.insert(pid)
            guard let info = Self.taskInfo(pid) else {
                // Another user's process (or one that just exited): only its path can be read.
                if otherUserInfo(pid).aiCandidate { candidates.append(pid) }
                continue
            }
            let cpuTicks = info.pti_total_user + info.pti_total_system
            let cpuNs = cpuTicks * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
            currentCPU[pid] = cpuNs

            // Resolve path/name/basename from the cache (immutable per pid). Cumulative CPU only
            // ever rises within one process, so cpuNs < prev means the pid was recycled onto a new
            // process → drop the stale entry and re-resolve.
            if let prev = previousCPU[pid], cpuNs < prev { infoCache[pid] = nil }
            let meta: PidInfo
            if let hit = infoCache[pid] {
                meta = hit
            } else {
                let p = Self.path(pid)
                meta = PidInfo(path: p, name: Self.name(pid), base: Self.basename(p))
                infoCache[pid] = meta
            }

            // argv only for AI-runtime candidates (gated by path basename; see wantsArgs) —
            // that's how mlx_lm / rapid-mlx / pip oMLX args are seen.
            var args: String? = nil
            if Self.wantsArgs(base: meta.base), let argv = Self.processArgs(pid), !argv.isEmpty {
                args = argv.joined(separator: " ")
            }

            rows.append(ProcessRow(
                pid: pid,
                name: meta.name,
                cpuPercent: cpuPercent(pid: pid, cpuNs: cpuNs, wallDelta: wallDelta),
                memoryBytes: info.pti_resident_size,
                path: meta.path,
                args: args
            ))
        }

        var others: [ProcessRow] = []
        if !candidates.isEmpty {
            let read = Self.readThroughPS(candidates)
            for pid in candidates {
                guard let r = read[pid] else { continue }   // exited between the list and ps
                // A recycled pid: its CPU time starts again, and its cached path is someone else's.
                if let prev = previousCPU[pid], r.cpuNs < prev { infoCache[pid] = nil }
                let meta = otherUserInfo(pid)
                guard meta.aiCandidate else { continue }
                currentCPU[pid] = r.cpuNs
                others.append(ProcessRow(
                    pid: pid,
                    name: meta.name,
                    cpuPercent: cpuPercent(pid: pid, cpuNs: r.cpuNs, wallDelta: wallDelta),
                    memoryBytes: r.residentBytes,
                    path: meta.path,
                    args: r.args.isEmpty ? nil : r.args
                ))
            }
        }

        previousCPU = currentCPU
        previousTimeNs = nowNs
        // Drop cached metadata for pids that are gone so the cache can't grow unbounded. Kept for
        // every listed pid, other users' included, so theirs is resolved once. One that is never
        // read again cannot notice its pid being reused, which is fine in practice: the kernel hands
        // out pids in sequence and a number returns only after the counter wraps (99,999).
        infoCache = infoCache.filter { listed.contains($0.key) }

        return ProcessTable(rows: Array(rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count)),
                            otherUsers: others)
    }

    /// CPU% over the last interval: the rise in cumulative CPU time over the wall time between the
    /// two reads. 0 on the first read of a pid, and when the counter went down (a recycled pid).
    private func cpuPercent(pid: pid_t, cpuNs: UInt64, wallDelta: Double) -> Double {
        guard let prev = previousCPU[pid], wallDelta > 0, cpuNs >= prev else { return 0 }
        return Double(cpuNs - prev) / wallDelta * 100.0
    }

    /// Another user's process as libproc gives it: the path, a name made from it (proc_name is
    /// refused), and whether it may be an AI runtime. Cached like this user's.
    private func otherUserInfo(_ pid: pid_t) -> PidInfo {
        if let hit = infoCache[pid] { return hit }
        let p = Self.path(pid)
        let base = Self.basename(p)
        let meta = PidInfo(path: p, name: base.isEmpty ? "pid \(pid)" : base, base: base,
                           aiCandidate: Self.mayBeAIRuntime(path: p))
        infoCache[pid] = meta
        return meta
    }

    // MARK: - Other users' processes, through /bin/ps

    /// What /bin/ps reports for one process.
    struct PSRead: Equatable {
        let residentBytes: UInt64
        let cpuNs: UInt64
        let args: String
    }

    /// ps over a handful of pids takes milliseconds; one still running after this is killed.
    static let psTimeout: TimeInterval = 2

    /// Reads memory, CPU time and argv for `pids` through /bin/ps (setuid root, so it reads other
    /// users' processes, which libproc refuses). A pid that exited in between is simply absent.
    /// Bounded because it runs inside a sampling tick (#86): a ps that has not answered within
    /// `psTimeout` is killed, and this sample simply lacks the other users' rows.
    static func readThroughPS(_ pids: [pid_t]) -> [pid_t: PSRead] {
        // -ww: never cut argv to a width; `=` drops the header; C locale keeps "0:01.23" in time.
        guard let data = BoundedCommand.run(
            "/bin/ps",
            ["-ww", "-o", "pid=,rss=,time=,args=", "-p", pids.map { String($0) }.joined(separator: ",")],
            environment: ["LC_ALL": "C"],
            timeout: psTimeout)
        else { return [:] }
        // A listed pid that is gone is left out and the rest still print. A pid above the kernel's
        // limit (99,999) makes ps refuse the whole list; these come from proc_listallpids, never are.
        return parsePS(String(decoding: data, as: UTF8.self))
    }

    /// Parses `ps -o pid=,rss=,time=,args=` lines: "  1234  56789  12:34.56 /path/to/prog --flag".
    /// rss is in KiB. args keeps its own spacing.
    static func parsePS(_ text: String) -> [pid_t: PSRead] {
        var result: [pid_t: PSRead] = [:]
        for line in text.split(separator: "\n") {
            var rest = Substring(line)
            func field() -> Substring {
                rest = rest.drop { $0 == " " }
                let token = rest.prefix { $0 != " " }
                rest = rest.dropFirst(token.count)
                return token
            }
            guard let pid = pid_t(field()), let rssKiB = UInt64(field()),
                  let cpuNs = psTimeNanoseconds(field()) else { continue }
            result[pid] = PSRead(residentBytes: rssKiB * 1024, cpuNs: cpuNs,
                                 args: String(rest.drop { $0 == " " }))
        }
        return result
    }

    /// ps's cumulative CPU time in nanoseconds. macOS prints "minutes:seconds.hundredths" with the
    /// minutes unbounded ("227:53.69"); hours ("h:mm:ss.ss") and a "days-" prefix are read too.
    static func psTimeNanoseconds(_ text: Substring) -> UInt64? {
        var days: Double = 0
        var clock = text
        if let dash = text.firstIndex(of: "-") {
            guard let d = Double(text[..<dash]) else { return nil }
            days = d
            clock = text[text.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds: Double = 0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            seconds = seconds * 60 + v
        }
        return UInt64(((days * 86_400 + seconds) * 1e9).rounded())
    }

    // MARK: - libproc helpers

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let byteCount = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return [] }
        let actual = Int(byteCount)
        return Array(pids.prefix(actual))
    }

    private static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return result == size ? info : nil
    }

    private static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cBuffer: buffer) : "pid \(pid)"
    }

    /// Full executable path, or "" if libproc denies it (root/other-user pids).
    private static func path(_ pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN) isn't importable into Swift (arithmetic
        // macro), so use its literal value.
        let maxSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: maxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cBuffer: buffer) : ""
    }

    private static func basename(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }

    /// Reads a process's argv via KERN_PROCARGS2. Sudoless for user-owned processes;
    /// returns nil if denied. Layout: [Int32 argc][exec_path\0...][\0 padding][argv0\0 argv1\0 ...].
    /// Battle-tested parser — handles argc framing, exec-path skip, and NUL padding.
    static func processArgs(_ pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        var mibAM = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibAM, 2, &argmax, &sz, nil, 0) == 0, argmax > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buf, MemoryLayout<Int32>.size)
        guard argc > 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        while cursor < size && buf[cursor] != 0 { cursor += 1 }      // skip exec path
        while cursor < size && buf[cursor] == 0 { cursor += 1 }      // skip NUL padding

        var result: [String] = []
        var collected = 0
        while collected < Int(argc) && cursor < size {
            let start = cursor
            while cursor < size && buf[cursor] != 0 { cursor += 1 }
            let arg = buf[start..<cursor].withUnsafeBufferPointer { p in
                String(decoding: p.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            result.append(arg)
            collected += 1
            cursor += 1
        }
        return result.isEmpty ? nil : result
    }
}
