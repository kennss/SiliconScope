//
//  File:      ProcessDetail.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  All per-process metrics the Process Inspector shows for ONE focused pid, derived
//             sudolessly from proc_pid_rusage(RUSAGE_INFO_V6). Gauges (memory, ANE memory, threads,
//             FDs) are read directly; rates (CPU%, IPC, power, disk, wakeups) are deltas of the
//             monotonic counters over a measured dt — exactly like MetricsEngine's memory rates.
//  Notes:     Verified on M1 (Phase 0): rusage time fields are MACH TICKS (convert with machToNs);
//             energy is `ri_energy_nj` (nanojoules → W); `ri_neural_footprint` is the genuine
//             per-process ANE-memory signal (e.g. a Whisper/CoreML app reads non-zero). `ri_billed_
//             energy` reads 0 — not used. Rates are nil on the first sample / dt<=0 / not-own.
//
import Foundation

/// Raw counters + gauges extracted from rusage_info_v6 (+ task/FD info). A small Swift value so the
/// rate math (`ProcessDetail.derive`) is pure and unit-testable without constructing the C struct.
public struct ProcRaw: Sendable, Equatable {
    // Monotonic counters (→ rate via delta/dt)
    public var userTimeMach: UInt64 = 0
    public var systemTimeMach: UInt64 = 0
    public var userPTimeMach: UInt64 = 0      // P-core user time
    public var systemPTimeMach: UInt64 = 0    // P-core system time
    public var instructions: UInt64 = 0
    public var cycles: UInt64 = 0
    public var energyNanojoules: UInt64 = 0
    public var diskReadBytes: UInt64 = 0
    public var diskWriteBytes: UInt64 = 0
    public var idleWakeups: UInt64 = 0
    public var interruptWakeups: UInt64 = 0
    // Gauges (read each tick)
    public var physFootprint: UInt64 = 0
    public var residentSize: UInt64 = 0
    public var neuralFootprint: UInt64 = 0        // per-process ANE memory (signature signal)
    public var neuralFootprintPeak: UInt64 = 0    // lifetime max
    public var threads: Int = 0
    public var openFiles: Int = 0
    public var startAbstime: UInt64 = 0
    public init() {}
}

public struct ProcessDetail: Sendable, Equatable, Codable, Identifiable {
    public let pid: Int32
    public let name: String
    public let path: String
    public let isOwn: Bool          // false → other user/root: identity only, metrics unavailable
    public var id: Int32 { pid }

    // Gauges
    public let memoryBytes: UInt64        // phys_footprint (the "Memory" Activity Monitor shows)
    public let residentBytes: UInt64
    public let aneMemoryBytes: UInt64     // neural_footprint — per-process ANE memory
    public let aneMemoryPeakBytes: UInt64
    public let threads: Int
    public let openFiles: Int
    public let uptime: TimeInterval

    // Rates (nil until a second sample exists; nil when not-own)
    public let cpuPercent: Double?        // total CPU%
    public let cpuPPercent: Double?       // P-core portion of CPU% (E = total - P)
    public let instructionsPerSec: Double?
    public let cyclesPerSec: Double?
    public let ipc: Double?               // instructions / cycles over the interval
    public let powerWatts: Double?        // ri_energy_nj delta → W
    public let diskReadBytesPerSec: Double?
    public let diskWriteBytesPerSec: Double?
    public let wakeupsPerSec: Double?

    /// True when this process holds ANE memory — i.e. it is using the Neural Engine.
    public var usesANE: Bool { aneMemoryBytes > 0 }

    /// Builds a ProcessDetail from the current raw sample + the previous one (for rates). Pure +
    /// testable. `machToNs` converts rusage's mach-tick time fields to nanoseconds (Apple Silicon
    /// ≈ 41.67). `nowMach` = mach_absolute_time() at sample time (for uptime). Rates are nil when
    /// there's no previous sample, dt<=0, or the process isn't ours.
    public static func derive(pid: Int32, name: String, path: String, isOwn: Bool,
                              prev: ProcRaw?, cur: ProcRaw, dt: TimeInterval,
                              nowMach: UInt64, machToNs: Double) -> ProcessDetail {
        let uptime = cur.startAbstime > 0 && nowMach > cur.startAbstime
            ? Double(nowMach - cur.startAbstime) * machToNs / 1_000_000_000 : 0

        guard isOwn, let p = prev, dt > 0 else {
            return ProcessDetail(pid: pid, name: name, path: path, isOwn: isOwn,
                                 memoryBytes: cur.physFootprint, residentBytes: cur.residentSize,
                                 aneMemoryBytes: cur.neuralFootprint, aneMemoryPeakBytes: cur.neuralFootprintPeak,
                                 threads: cur.threads, openFiles: cur.openFiles, uptime: uptime,
                                 cpuPercent: nil, cpuPPercent: nil, instructionsPerSec: nil,
                                 cyclesPerSec: nil, ipc: nil, powerWatts: nil,
                                 diskReadBytesPerSec: nil, diskWriteBytesPerSec: nil, wakeupsPerSec: nil)
        }

        func d(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }
        let dtNs = dt * 1_000_000_000

        // CPU time fields are mach ticks → ns; CPU% = busy-ns / elapsed-ns × 100.
        let cpuNs = (d(p.userTimeMach, cur.userTimeMach) + d(p.systemTimeMach, cur.systemTimeMach)) * machToNs
        let pNs = (d(p.userPTimeMach, cur.userPTimeMach) + d(p.systemPTimeMach, cur.systemPTimeMach)) * machToNs
        let instr = d(p.instructions, cur.instructions)
        let cyc = d(p.cycles, cur.cycles)

        return ProcessDetail(pid: pid, name: name, path: path, isOwn: isOwn,
                             memoryBytes: cur.physFootprint, residentBytes: cur.residentSize,
                             aneMemoryBytes: cur.neuralFootprint, aneMemoryPeakBytes: cur.neuralFootprintPeak,
                             threads: cur.threads, openFiles: cur.openFiles, uptime: uptime,
                             cpuPercent: cpuNs / dtNs * 100,
                             cpuPPercent: pNs / dtNs * 100,
                             instructionsPerSec: instr / dt,
                             cyclesPerSec: cyc / dt,
                             ipc: cyc > 0 ? instr / cyc : nil,
                             powerWatts: Double(d(p.energyNanojoules, cur.energyNanojoules)) / 1_000_000_000 / dt,
                             diskReadBytesPerSec: d(p.diskReadBytes, cur.diskReadBytes) / dt,
                             diskWriteBytesPerSec: d(p.diskWriteBytes, cur.diskWriteBytes) / dt,
                             wakeupsPerSec: (d(p.idleWakeups, cur.idleWakeups) + d(p.interruptWakeups, cur.interruptWakeups)) / dt)
    }
}
