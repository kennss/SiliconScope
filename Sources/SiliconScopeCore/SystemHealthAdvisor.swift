//
//  File:      SystemHealthAdvisor.swift
//  Created:   2026-07-02
//  Developer: zhangchen / Mindstream
//  Overview:  System health classifier — detects CPU overload, identifies top offending
//             processes, and generates actionable suggestions ("Quit X to free Y% CPU").
//             Pure value logic, no UI or syscalls. Consumes data already in SystemSnapshot
//             + load average + core count.
//  Notes:     Modeled after Bottleneck.swift — a pure classify() function with no state.
//             Load average is compared against total core count (E+P) since macOS schedules
//             across all cores. Offenders are filtered to non-system, non-foreground processes
//             above a threshold.
//
import Foundation

// MARK: - Health verdict

public struct HealthVerdict: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable {
        case healthy        // load < 1.5× cores, memory OK
        case stressed       // load 1.5–2.5× cores, or memory warning
        case overloaded     // load > 2.5× cores, or memory critical + high swap
    }

    public let level: Level
    public let loadAverage: Double          // 1-minute load average
    public let coreCount: Int               // total logical cores (E+P)
    public let loadRatio: Double            // loadAverage / coreCount
    public let offenders: [Offender]        // top CPU hogs, sorted descending
    public let memoryFreeMB: Double         // free (unused) physical memory in MB
    public let suggestion: String?          // human-readable action suggestion

    public init(level: Level, loadAverage: Double, coreCount: Int, loadRatio: Double,
                offenders: [Offender], memoryFreeMB: Double, suggestion: String?) {
        self.level = level
        self.loadAverage = loadAverage
        self.coreCount = coreCount
        self.loadRatio = loadRatio
        self.offenders = offenders
        self.memoryFreeMB = memoryFreeMB
        self.suggestion = suggestion
    }

    /// Short UI label for the health state.
    public var label: String {
        switch level {
        case .healthy:    return "Healthy"
        case .stressed:   return "Stressed"
        case .overloaded: return "Overloaded"
        }
    }

    /// One-line explanation.
    public var detail: String {
        switch level {
        case .healthy:    return "System running normally"
        case .stressed:   return "High load — performance may degrade"
        case .overloaded: return "System overloaded — expect lag and unresponsiveness"
        }
    }
}

// MARK: - Offender

public struct Offender: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryMB: Double
    public let isSystemProcess: Bool    // if true, user shouldn't quit it

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryMB: Double, isSystemProcess: Bool) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
        self.isSystemProcess = isSystemProcess
    }
}

// MARK: - Classifier

public enum SystemHealthAdvisor {

    // MARK: - Thresholds

    /// Load / cores ratio thresholds.
    private static let stressedThreshold = 1.5
    private static let overloadedThreshold = 2.5

    /// Minimum CPU% for a process to be considered an offender.
    private static let offenderCPUThreshold = 15.0

    /// Maximum offenders to report.
    private static let maxOffenders = 5

    /// Well-known system process prefixes/names that the user should NOT quit.
    private static let systemProcesses: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "mds", "mds_stores",
        "opendirectoryd", "fseventsd", "coreaudiod", "distnoted",
        "cfprefsd", "logd", "powerd", "thermald", "symptomsd",
        "trustd", "securityd", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "ControlCenter", "NotificationCenter",
        "AirPlayUIAgent", "Spotlight", "PerfPowerServices",
        "runningboardd", "coreduetd", "nsurlsessiond", "CoreServicesUIAgent"
    ]

    // MARK: - Public API

    /// Classifies system health from the current snapshot + load average.
    /// `loadAverage` should be the 1-minute value from `getloadavg()`.
    /// `coreCount` is total logical cores (E+P) from CPUTopology.
    public static func classify(
        processes: [ProcessRow],
        loadAverage: Double,
        coreCount: Int,
        memoryPressure: MemorySample.Pressure,
        memoryFreeBytes: UInt64,
        swapOutRate: Double
    ) -> HealthVerdict {
        let cores = max(coreCount, 1)
        let loadRatio = loadAverage / Double(cores)
        let memoryFreeMB = Double(memoryFreeBytes) / (1024 * 1024)

        // Determine level
        let level: HealthVerdict.Level
        if loadRatio >= overloadedThreshold || (memoryPressure == .critical && swapOutRate > 10) {
            level = .overloaded
        } else if loadRatio >= stressedThreshold || memoryPressure == .warning {
            level = .stressed
        } else {
            level = .healthy
        }

        // Identify offenders (non-system processes eating significant CPU)
        let offenders = identifyOffenders(processes: processes)

        // Generate suggestion
        let suggestion: String?
        if level != .healthy && !offenders.isEmpty {
            suggestion = buildSuggestion(offenders: offenders, level: level)
        } else {
            suggestion = nil
        }

        return HealthVerdict(
            level: level,
            loadAverage: loadAverage,
            coreCount: cores,
            loadRatio: loadRatio,
            offenders: offenders,
            memoryFreeMB: memoryFreeMB,
            suggestion: suggestion
        )
    }

    // MARK: - Private helpers

    private static func identifyOffenders(processes: [ProcessRow]) -> [Offender] {
        processes
            .filter { $0.cpuPercent >= offenderCPUThreshold }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(maxOffenders)
            .map { proc in
                Offender(
                    pid: proc.pid,
                    name: proc.name,
                    cpuPercent: proc.cpuPercent,
                    memoryMB: Double(proc.memoryBytes) / (1024 * 1024),
                    isSystemProcess: isSystem(proc)
                )
            }
    }

    private static func isSystem(_ proc: ProcessRow) -> Bool {
        // Check name against known system processes
        if systemProcesses.contains(proc.name) { return true }
        // Processes in /usr/libexec, /System, or /usr/sbin are system
        let path = proc.path
        if path.hasPrefix("/usr/libexec/") || path.hasPrefix("/System/") ||
           path.hasPrefix("/usr/sbin/") || path.hasPrefix("/usr/bin/") {
            return true
        }
        return false
    }

    private static func buildSuggestion(offenders: [Offender], level: HealthVerdict.Level) -> String {
        // Filter to quittable (non-system) offenders
        let quittable = offenders.filter { !$0.isSystemProcess }
        guard !quittable.isEmpty else {
            return "High system load from OS processes — consider restarting"
        }

        let totalCPU = quittable.reduce(0.0) { $0 + $1.cpuPercent }
        let names = quittable.prefix(3).map { $0.name }

        if names.count == 1 {
            return "Quit \(names[0]) to free ~\(Int(totalCPU))% CPU"
        } else {
            let joined = names.dropLast().joined(separator: ", ") + " & " + names.last!
            return "Quit \(joined) to free ~\(Int(totalCPU))% CPU"
        }
    }
}
