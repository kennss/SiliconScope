//
//  File:      ProcessRow.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  One row of the process table: pid, name, CPU%, resident memory, plus the
//             full executable path and (for AI-runtime candidates only) the argv string.
//  Notes:     cpuPercent is summed across cores (top-style, can exceed 100). It is a
//             delta between two ProcessSampler reads, so the first read reports 0.
//             path is "" when libproc denies it (system pids) — callers fall back to
//             name. args is nil unless the process is an AI-runtime candidate (gated
//             KERN_PROCARGS2 read). Both default in init for source compatibility.
//
import Foundation

public struct ProcessRow: Sendable, Equatable, Identifiable, Codable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let path: String          // full executable path; "" if libproc denied it
    public let args: String?         // argv joined by spaces; nil unless an AI-runtime candidate

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64,
                path: String = "", args: String? = nil) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.path = path
        self.args = args
    }

    public var memoryMB: Double { Double(memoryBytes) / (1024.0 * 1024.0) }
}
