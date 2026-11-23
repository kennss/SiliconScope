//
//  File:      ProcessDetailHistory.swift
//  Created:   2026-06-25
//  Updated:   2026-11-23
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Rolling history for the focused process (the Inspector's charts), capped at
//             MetricsEngine.History.capacity so its bar charts fill a card as the dashboard's do.
//             A fresh instance is created on each focus change.
//  Notes:     A nil rate (first sample, not-own process, IPC with no cycles) is pushed as NaN: a
//             gap the charts leave blank, which keeps the series aligned without claiming a
//             measured 0.
//
import Foundation

public struct ProcessDetailHistory: Sendable {
    public static let capacity = MetricsEngine.History.capacity

    public var cpu: [Double] = []           // %
    public var memory: [Double] = []        // GB (phys footprint)
    public var power: [Double] = []         // W
    public var ipc: [Double] = []
    public var aneMemory: [Double] = []     // GB (neural footprint)
    public var diskRead: [Double] = []      // bytes/s
    public var diskWrite: [Double] = []     // bytes/s
    public var wakeups: [Double] = []       // /s
    public init() {}

    public mutating func push(_ d: ProcessDetail) {
        roll(&cpu, d.cpuPercent ?? .nan)
        roll(&memory, Double(d.memoryBytes) / 1_073_741_824)
        roll(&power, d.powerWatts ?? .nan)
        roll(&ipc, d.ipc ?? .nan)
        roll(&aneMemory, Double(d.aneMemoryBytes) / 1_073_741_824)
        roll(&diskRead, d.diskReadBytesPerSec ?? .nan)
        roll(&diskWrite, d.diskWriteBytesPerSec ?? .nan)
        roll(&wakeups, d.wakeupsPerSec ?? .nan)
    }
    private func roll(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > Self.capacity { series.removeFirst(series.count - Self.capacity) }
    }
}
