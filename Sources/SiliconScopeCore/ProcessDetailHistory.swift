//
//  File:      ProcessDetailHistory.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Rolling ~60-sample sparkline history for the focused process, mirroring
//             MetricsEngine.History's roll/cap. A fresh instance is created on each focus change.
//  Notes:     nil rates (first sample / not-own) are pushed as 0 so the series stay aligned.
//
import Foundation

public struct ProcessDetailHistory: Sendable {
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
        roll(&cpu, d.cpuPercent ?? 0)
        roll(&memory, Double(d.memoryBytes) / 1_073_741_824)
        roll(&power, d.powerWatts ?? 0)
        roll(&ipc, d.ipc ?? 0)
        roll(&aneMemory, Double(d.aneMemoryBytes) / 1_073_741_824)
        roll(&diskRead, d.diskReadBytesPerSec ?? 0)
        roll(&diskWrite, d.diskWriteBytesPerSec ?? 0)
        roll(&wakeups, d.wakeupsPerSec ?? 0)
    }
    private func roll(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > 60 { series.removeFirst(series.count - 60) }
    }
}
