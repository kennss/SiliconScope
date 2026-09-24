//
//  File:      ANESample.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  How busy the Neural Engine was over one sampling slice — MEASURED residency, not a
//             power proxy. The first direct ANE activity reading SiliconScope has had.
//  Notes:     Source: IOReport "SoC Stats" › "Cluster Power States", one state channel per ANE
//             cluster (ANE0, ANE1 …) with ACT / INACT residencies. The fraction of the slice spent
//             in ACT is the same construction as GPU utilisation (active residency ÷ total).
//
//             Why it exists: macOS 27 stopped updating the ANE energy counter more than every few
//             minutes on M1-class Macs (#65), and ANE watts had been the ONLY evidence of ANE work.
//             Measured on an M1 Max while WhisperKit transcribed: ANE0 ACT for the entire 2 s window,
//             SOC0_ANE_F2 (its high clock level) 86 % of it, ANE0 DRAM reads ≈ 19 GB/s — while the
//             ANE power counter had not moved in minutes.
//
//             `activeFraction` is the busiest cluster. A Max has one ANE (ANE1 exists as a channel
//             and never activates); an Ultra has one per die. Averaging would read a fully busy
//             Max as 50 %.
//
import Foundation

public struct ANESample: Sendable, Equatable, Codable {
    /// 0…1 — share of the slice the busiest ANE cluster was powered and active.
    public var activeFraction: Double = 0
    /// Per cluster, in channel order (ANE0, ANE1 …), each 0…1.
    public var clusters: [Double] = []

    public init(activeFraction: Double = 0, clusters: [Double] = []) {
        self.activeFraction = activeFraction
        self.clusters = clusters
    }
}
