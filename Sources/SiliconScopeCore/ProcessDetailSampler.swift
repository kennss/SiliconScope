//
//  File:      ProcessDetailSampler.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Samples ONE focused pid sudolessly via proc_pid_rusage(RUSAGE_INFO_V6) plus
//             proc_pidinfo (thread + open-file counts) and proc_name/proc_pidpath, producing a
//             ProcessDetail. Holds the previous raw sample so rates are deltas over the caller's
//             dt (the same dt the monitor computes for MetricsEngine). One sampler per focus.
//  Notes:     Returns nil when the process has exited or the pid was reused (start-abstime guard).
//             For a process we don't own (root/other user) rusage is denied — we return an
//             identity-only ProcessDetail (isOwn=false) rather than nil so the UI can say so.
//             rusage time fields are mach ticks → ns via the cached timebase (Phase-0 verified).
//
import Foundation
import Darwin

public final class ProcessDetailSampler {
    public let pid: Int32
    private var previousRaw: ProcRaw?
    private var startAbstime: UInt64 = 0     // captured on first sample → pid-reuse guard
    private let machToNs: Double

    public init(pid: Int32) {
        self.pid = pid
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        machToNs = tb.denom > 0 ? Double(tb.numer) / Double(tb.denom) : 1
    }

    /// Samples the focused pid over `dt` seconds since the previous sample. nil ⇒ process gone /
    /// pid reused. First sample (or not-own) yields a ProcessDetail with nil rates.
    public func sample(dt: TimeInterval) -> ProcessDetail? {
        let name = Self.name(pid)
        let path = Self.path(pid)

        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }

        // Not our process (denied): if it still exists, return identity only.
        if rc != 0 {
            guard !name.isEmpty || !path.isEmpty else { return nil }   // gone
            return ProcessDetail.derive(pid: pid, name: name, path: path, isOwn: false,
                                        prev: nil, cur: ProcRaw(), dt: 0,
                                        nowMach: mach_absolute_time(), machToNs: machToNs)
        }
        guard info.ri_proc_exit_abstime == 0 else { return nil }       // exited
        if startAbstime == 0 { startAbstime = info.ri_proc_start_abstime }
        else if startAbstime != info.ri_proc_start_abstime { return nil }  // pid reused

        var cur = ProcRaw()
        cur.userTimeMach = info.ri_user_time
        cur.systemTimeMach = info.ri_system_time
        cur.userPTimeMach = info.ri_user_ptime
        cur.systemPTimeMach = info.ri_system_ptime
        cur.instructions = info.ri_instructions
        cur.cycles = info.ri_cycles
        cur.energyNanojoules = info.ri_energy_nj
        cur.diskReadBytes = info.ri_diskio_bytesread
        cur.diskWriteBytes = info.ri_diskio_byteswritten
        cur.idleWakeups = info.ri_pkg_idle_wkups
        cur.interruptWakeups = info.ri_interrupt_wkups
        cur.physFootprint = info.ri_phys_footprint
        cur.residentSize = info.ri_resident_size
        cur.neuralFootprint = info.ri_neural_footprint
        cur.neuralFootprintPeak = info.ri_lifetime_max_neural_footprint
        cur.threads = Self.threadCount(pid)
        cur.openFiles = Self.openFileCount(pid)
        cur.startAbstime = info.ri_proc_start_abstime

        let detail = ProcessDetail.derive(pid: pid, name: name, path: path, isOwn: true,
                                          prev: previousRaw, cur: cur, dt: dt,
                                          nowMach: mach_absolute_time(), machToNs: machToNs)
        previousRaw = cur
        return detail
    }

    // MARK: - libproc helpers
    private static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256); proc_name(pid, &buf, 256)
        return String(cString: buf)
    }
    private static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096); proc_pidpath(pid, &buf, 4096)
        return String(cString: buf)
    }
    private static func threadCount(_ pid: Int32) -> Int {
        var ti = proc_taskinfo()
        let sz = proc_pidinfo(pid, Int32(PROC_PIDTASKINFO), 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return sz > 0 ? Int(ti.pti_threadnum) : 0
    }
    private static func openFileCount(_ pid: Int32) -> Int {
        let bytes = proc_pidinfo(pid, Int32(PROC_PIDLISTFDS), 0, nil, 0)
        return bytes > 0 ? Int(bytes) / MemoryLayout<proc_fdinfo>.size : 0
    }
}
