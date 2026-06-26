//
//  File:      CPUSample.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one CPU reading split by Apple Silicon cluster
//             type: efficiency (E) vs performance (P).
//  Notes:     usage is 0...1 (fraction of active residency). freq is the
//             residency-weighted average clock in MHz across that cluster type.
//
import Foundation

public struct CPUSample: Sendable, Equatable, Codable {
    public var eUsage: Double = 0       // efficiency cluster, 0...1
    public var pUsage: Double = 0       // performance cluster(s), 0...1
    public var eFreqMHz: Double = 0
    public var pFreqMHz: Double = 0

    public init() {}

    public var eUsagePercent: Double { eUsage * 100 }
    public var pUsagePercent: Double { pUsage * 100 }
}
