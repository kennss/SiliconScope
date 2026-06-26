//
//  File:      MemorySample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unified-memory reading split into the VM categories that sum to the total
//             (Wired + Active + Compressed + Free), plus swap and lifetime VM counters.
//  Notes:     used = wired + active + compressed (these add up to what the bar shows);
//             free = total - used (folds in inactive/speculative). wiredBytes includes
//             Metal/GPU allocations — a key signal for local-LLM workloads.
//             compressions/swapins/swapouts/pageouts are cumulative lifetime page
//             counters (vm_statistics64); the monitor diffs them into rates — the real
//             precursor to a tokens/sec collapse, not the static used% (cache keeps it high).
//
import Foundation

public struct MemorySample: Sendable, Equatable, Codable {
    public enum Pressure: String, Sendable, Equatable, Codable { case normal, warning, critical }

    public var totalBytes: UInt64 = 0
    public var wiredBytes: UInt64 = 0
    public var activeBytes: UInt64 = 0
    public var compressedBytes: UInt64 = 0
    public var appMemoryBytes: UInt64 = 0     // Activity Monitor "App Memory" = internal - purgeable
    public var cachedFilesBytes: UInt64 = 0   // "Cached Files" = external + purgeable (evictable)
    public var swapTotalBytes: UInt64 = 0
    public var swapUsedBytes: UInt64 = 0
    public var pressure: Pressure = .normal   // macOS memory pressure level

    // Cumulative lifetime page counters (vm_statistics64). Monotonic; the monitor
    // diffs consecutive samples into rates to detect swap/compression pressure early.
    public var compressions: UInt64 = 0
    public var swapins: UInt64 = 0
    public var swapouts: UInt64 = 0
    public var pageins: UInt64 = 0
    public var pageouts: UInt64 = 0

    public init() {}

    public var usedBytes: UInt64 { wiredBytes + activeBytes + compressedBytes }
    public var freeBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }

    private static let gb = 1024.0 * 1024.0 * 1024.0
    public var totalGB: Double { Double(totalBytes) / Self.gb }
    public var usedGB: Double { Double(usedBytes) / Self.gb }
    public var wiredGB: Double { Double(wiredBytes) / Self.gb }
    public var activeGB: Double { Double(activeBytes) / Self.gb }
    public var compressedGB: Double { Double(compressedBytes) / Self.gb }
    public var freeGB: Double { Double(freeBytes) / Self.gb }
    public var appMemoryGB: Double { Double(appMemoryBytes) / Self.gb }
    public var cachedFilesGB: Double { Double(cachedFilesBytes) / Self.gb }
    public var swapUsedGB: Double { Double(swapUsedBytes) / Self.gb }

    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    public var usedPercent: Double { usedFraction * 100 }

    /// Memory pressure as a percentage — the share of RAM that can't be easily reclaimed
    /// (wired + compressed). Matches the figure Activity Monitor / iStat show; the `pressure`
    /// enum (from the kernel) is the authoritative green/yellow/red level.
    public var pressurePercent: Double {
        totalBytes > 0 ? Double(wiredBytes + compressedBytes) / Double(totalBytes) * 100 : 0
    }

    // Fractions of total for a stacked bar.
    public var wiredFraction: Double { totalBytes > 0 ? Double(wiredBytes) / Double(totalBytes) : 0 }
    public var activeFraction: Double { totalBytes > 0 ? Double(activeBytes) / Double(totalBytes) : 0 }
    public var compressedFraction: Double { totalBytes > 0 ? Double(compressedBytes) / Double(totalBytes) : 0 }
    public var freeFraction: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0 }
}
