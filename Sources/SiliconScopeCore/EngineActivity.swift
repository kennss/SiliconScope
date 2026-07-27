//
//  File:      EngineActivity.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Latched "is this engine doing work" flags for the AI Workload card's CPU / GPU / ANE
//             / Media rows. A bare threshold on a live sample flaps: a GPU hovering around the
//             busy line alternates active/idle every tick, which reads as instability in the
//             MACHINE when it is really instability in the QUESTION.
//  Notes:     Two mechanisms, both needed:
//             - **hysteresis** — the level that turns a row ON is higher than the one that lets it
//               go OFF, so a value sitting exactly on one boundary cannot oscillate;
//             - **dwell** — a change must persist for N ticks before it is shown, so a single
//               spike or dropout does not flip the label.
//             ⚠️ Only the STATE is latched. The numbers beside it stay live — the row shows its
//             evidence every tick, and only the verdict is held steady.
//             `onDwell` < `offDwell` on purpose: an engine lighting up is the event worth seeing
//             promptly; an engine going quiet is worth confirming.
//
import Foundation

/// One hysteretic, dwell-filtered boolean.
public struct ActivityLatch: Sendable, Equatable {
    /// The latched state — what the UI should show.
    public private(set) var isOn: Bool
    /// Consecutive ticks the raw signal has disagreed with `isOn`.
    private var streak: Int = 0

    public init(isOn: Bool = false) { self.isOn = isOn }

    /// Feeds one tick.
    ///
    /// - Parameter raw: the threshold test, evaluated by the caller **using `isOn`** so it can
    ///   apply hysteresis (a lower bar to stay on than to turn on).
    /// - Parameters onDwell/offDwell: how many consecutive disagreeing ticks are required.
    @discardableResult
    public mutating func update(_ raw: Bool, onDwell: Int = 2, offDwell: Int = 4) -> Bool {
        guard raw != isOn else { streak = 0; return isOn }
        streak += 1
        if streak >= (raw ? onDwell : offDwell) {
            isOn = raw
            streak = 0
        }
        return isOn
    }
}

/// Which engines are working, held steady enough to read.
public struct EngineActivity: Sendable, Equatable {
    private var cpuLatch = ActivityLatch()
    private var gpuLatch = ActivityLatch()
    private var aneLatch = ActivityLatch()
    private var mediaLatch = ActivityLatch()

    public init() {}

    /// Seeds directly from one sample, with no dwell — for surfaces that have no time series to
    /// latch over (a remote machine's wire metrics). Uses the ON thresholds, so it agrees with
    /// what a latched instance would settle to.
    public init(instant s: SystemSnapshot) {
        cpuLatch = ActivityLatch(isOn: s.cpu.pUsage > Threshold.cpuPerfOn || s.cpu.eUsage > Threshold.cpuEffOn)
        gpuLatch = ActivityLatch(isOn: s.gpu.usage > Threshold.gpuUsageOn || s.power.gpuWatts > Threshold.gpuWattsOn)
        aneLatch = ActivityLatch(isOn: s.power.aneWatts > Threshold.aneWattsOn)
        mediaLatch = ActivityLatch(isOn: s.bandwidth.mediaGBs > Threshold.mediaGBsOn)
    }

    public var cpu: Bool { cpuLatch.isOn }
    public var gpu: Bool { gpuLatch.isOn }
    public var ane: Bool { aneLatch.isOn }
    public var media: Bool { mediaLatch.isOn }

    /// Thresholds. The `on` value is the level at which an engine is doing real work; the `off`
    /// value is how far it must fall back before we say it stopped.
    ///
    /// ⚠️ The GPU pair is deliberately wide. macOS never lets the GPU reach zero — the compositor
    /// draws windows — so "busy" has to mean *compute*, and 30 % at 0.3 W on the minimum clock is
    /// not compute. Narrow the gap and the row flaps every time a window moves.
    public enum Threshold {
        public static let cpuPerfOn = 0.20, cpuPerfOff = 0.12
        public static let cpuEffOn = 0.35, cpuEffOff = 0.22
        public static let gpuUsageOn = 0.40, gpuUsageOff = 0.25
        public static let gpuWattsOn = 4.0, gpuWattsOff = 2.0
        public static let aneWattsOn = 0.5, aneWattsOff = 0.25
        public static let mediaGBsOn = 0.1, mediaGBsOff = 0.05
    }

    /// Feeds one sample. Call once per tick, in order.
    public mutating func update(_ s: SystemSnapshot) {
        cpuLatch.update(cpu
            ? (s.cpu.pUsage > Threshold.cpuPerfOff || s.cpu.eUsage > Threshold.cpuEffOff)
            : (s.cpu.pUsage > Threshold.cpuPerfOn  || s.cpu.eUsage > Threshold.cpuEffOn))

        gpuLatch.update(gpu
            ? (s.gpu.usage > Threshold.gpuUsageOff || s.power.gpuWatts > Threshold.gpuWattsOff)
            : (s.gpu.usage > Threshold.gpuUsageOn  || s.power.gpuWatts > Threshold.gpuWattsOn))

        aneLatch.update(ane ? s.power.aneWatts > Threshold.aneWattsOff
                            : s.power.aneWatts > Threshold.aneWattsOn)

        mediaLatch.update(media ? s.bandwidth.mediaGBs > Threshold.mediaGBsOff
                                : s.bandwidth.mediaGBs > Threshold.mediaGBsOn)
    }
}
