//
//  File:      MetricsEngine.swift
//  Created:   2026-06-25
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The path-dependent derivation that turns a stream of SystemSnapshots into the
//             values the dashboard reads beyond the raw snapshot: rolling sparkline History,
//             slowly-decaying peaks (bandwidth/media/ANE/GPU-clock), memory-rate deltas, and the
//             computed throttle / ceiling / bottleneck / memory-risk verdicts. Extracted from
//             SiliconScopeMonitor so the SAME logic drives both the live monitor and session
//             replay — guaranteeing the replayed dashboard matches what was shown live.
//  Notes:     Pure (no UI, no syscalls). `ingest(_:dt:)` advances one frame; `dt` is the seconds
//             since the previous frame (wall-clock when live, the recording's frame delta when
//             replaying) — the rates are deterministic in `dt`. Decay/floor constants and
//             thresholds are copied verbatim from the previous inline monitor logic.
//
import Foundation

public final class MetricsEngine {
    /// Rolling time-series for sparklines (last ~60 samples per series).
    public struct History: Sendable {
        public var soc: [Double] = []
        public var pCPU: [Double] = []         // 0...1
        public var eCPU: [Double] = []         // 0...1
        public var gpu: [Double] = []          // 0...1
        public var gpuMem: [Double] = []       // 0...1 (GPU in-use memory / total unified memory)
        public var ane: [Double] = []          // Watts
        public var media: [Double] = []        // GB/s (Media Engine)
        public var bandwidth: [Double] = []    // GB/s
        public var dieTemp: [Double] = []      // Celsius (CPU sensor average)
        /// Per-category sensor maxima in °C, keyed by the category the machine actually reports —
        /// a fanless Air has no GPU group, a Mac mini no battery. `dieTemp` covers only the CPU,
        /// so a chart of "the sensors" needs this.
        public var sensorGroups: [SensorCategory: [Double]] = [:]
        public var memory: [Double] = []       // GB used
        public var memFraction: [Double] = []  // 0...1 (used / total) — plotted on a fixed 0...1 axis
        public var netDown: [Double] = []      // bytes/s
        public var netUp: [Double] = []        // bytes/s
        public var diskRead: [Double] = []     // bytes/s
        public var diskWrite: [Double] = []    // bytes/s

        public init() {}

        /// Appends one frame. A group absent from `measured` was NOT read this tick, and its
        /// series takes a GAP rather than the snapshot's zero-initialised default.
        ///
        /// ⚠️ Every series advances by exactly one slot per tick, gap or not. That is the point:
        /// these series carry no timestamps, so the only thing keeping two charts on a shared
        /// time axis is that they are the same length and advance together. Skipping the append
        /// for an unmeasured group would leave its last hour of samples sitting against the CPU
        /// chart's last minute, drawn as if they were the same minute — a quieter lie than a
        /// zero, and a harder one to see.
        public mutating func push(_ s: SystemSnapshot, measured: MetricGroup = .all) {
            func value(_ group: MetricGroup, _ v: @autoclosure () -> Double) -> Double {
                measured.contains(group) ? v() : .nan
            }
            roll(&soc, value(.power, s.power.socWatts))
            roll(&pCPU, value(.cpu, s.cpu.pUsage))
            roll(&eCPU, value(.cpu, s.cpu.eUsage))
            roll(&gpu, value(.gpu, s.gpu.usage))
            roll(&gpuMem, value(.gpu, s.gpu.inUseMemoryFraction))
            roll(&ane, value(.power, s.power.aneWatts))
            roll(&media, value(.bandwidth, s.bandwidth.mediaGBs))
            roll(&bandwidth, value(.bandwidth, s.bandwidth.totalGBs))
            roll(&dieTemp, value(.temperature, s.temperature.cpuCelsius))
            // The card lists one row per group; this gives each row a series to be drawn from.
            // On a gap the machine reports no groups, so advance the ones already known instead
            // of letting their series stall out of step with the rest.
            if measured.contains(.temperature) {
                for group in s.temperature.groups {
                    var series = sensorGroups[group.category] ?? []
                    roll(&series, group.maximum)
                    sensorGroups[group.category] = series
                }
            } else {
                for category in sensorGroups.keys {
                    var series = sensorGroups[category] ?? []
                    roll(&series, .nan)
                    sensorGroups[category] = series
                }
            }
            roll(&memory, value(.memory, s.memory.usedGB))
            roll(&memFraction, value(.memory, s.memory.usedFraction))
            roll(&netDown, value(.network, s.network.downloadBytesPerSec))
            roll(&netUp, value(.network, s.network.uploadBytesPerSec))
            roll(&diskRead, value(.disk, s.disk.readBytesPerSec))
            roll(&diskWrite, value(.disk, s.disk.writeBytesPerSec))
        }
        private func roll(_ series: inout [Double], _ value: Double) {
            series.append(value)
            if series.count > 60 { series.removeFirst(series.count - 60) }
        }
    }

    // Latest ingested snapshot — the basis for the snapshot-dependent computed verdicts.
    public private(set) var latest = SystemSnapshot()
    public private(set) var history = History()
    /// Latched per-engine activity — see `EngineActivity`. Derived over TIME, so it lives with the
    /// engine rather than on the (stateless) snapshot.
    public private(set) var activity = EngineActivity()

    // Chip-agnostic bar scaling: track observed peaks instead of hardcoding per-chip maxima.
    public private(set) var bandwidthPeakGBs: Double = 80
    public private(set) var mediaPeakGBs: Double = 2
    public private(set) var anePeakWatts: Double = 2
    public private(set) var gpuClockPeakMHz: Double = 0
    private static let peakDecay = 0.999
    private static let gpuClockPeakDecay = 0.999

    // Memory-pressure precursor: rate deltas of the lifetime VM counters (pages/sec).
    public private(set) var memoryPageInRate: Double = 0
    public private(set) var memoryPageOutRate: Double = 0
    public private(set) var memorySwapInRate: Double = 0     // recovery reads (normal)
    public private(set) var memorySwapOutRate: Double = 0    // swapouts/sec — eviction under pressure
    public private(set) var memoryCompressionRate: Double = 0
    private static let compressionRatePagesPerSec = 200.0
    private struct MemCounters { let pageins, pageouts, swapins, swapouts, compressions: UInt64 }
    private var previousMem: MemCounters?

    private let topology: CPUTopology?

    public init(topology: CPUTopology?) { self.topology = topology }

    /// Advances the engine by one frame. `dt` = seconds since the previous frame.
    /// Advances the engine by one frame. `dt` = seconds since the previous frame. `measured` is
    /// the set of groups this frame actually read — anything else in `s` is a carried-forward
    /// value, and must not move a peak, a rate or a history series.
    ///
    /// ⚠️ The peaks DECAY. Folding a carried-forward value back in every tick would pin a peak to
    /// a number that stopped being observed, so an unmeasured group's peak is left entirely alone
    /// — neither raised nor decayed — and resumes from where the last real reading left it.
    public func ingest(_ s: SystemSnapshot, dt: TimeInterval, measured demanded: MetricGroup = .all) {
        // Power sampled but not KNOWN — macOS 27's slow energy counters before their first full
        // window (#65) — is the same fact as power not sampled: the zeros in it are placeholders.
        // Folding it here means the history gets a gap rather than a stretch of 0 W, and the ANE
        // peak and activity latch are not pulled down by readings that were never taken.
        let measured = s.power.railsKnown ? demanded : demanded.subtracting(.power)
        latest = s
        if measured.contains(.bandwidth) {
            bandwidthPeakGBs = max(s.bandwidth.totalGBs, max(40, bandwidthPeakGBs * Self.peakDecay))
            mediaPeakGBs = max(s.bandwidth.mediaGBs, max(1, mediaPeakGBs * Self.peakDecay))
        }
        if measured.contains(.power) {
            anePeakWatts = max(s.power.aneWatts, max(1, anePeakWatts * Self.peakDecay))
        }
        if measured.contains(.gpu) {
            gpuClockPeakMHz = max(s.gpu.freqMHz, gpuClockPeakMHz * Self.gpuClockPeakDecay)
        }
        // The rate is a delta between two readings of the same counters. Feeding it a repeat of
        // the previous sample would report a real machine as having paged nothing.
        if measured.contains(.memory) { updateMemoryRates(s.memory, dt: dt) }
        history.push(s, measured: measured)
        // The latches judge the present, so they are handed the demand and decide per domain
        // whether its power is live — an average over half an hour cannot say what is active now.
        activity.update(s, measured: demanded)
    }

    /// Clears rate state so the next frame emits no spurious delta (e.g. after a (re)start).
    public func reset() {
        previousMem = nil
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }

    // MARK: - Computed verdicts (snapshot + path-dependent state)
    //
    // The instance properties delegate to pure static functions so the replay path can compute the
    // EXACT same verdicts from a recorded frame's snapshot + precomputed scalars + rebuilt history.

    public var gpuThrottling: Bool { Self.gpuThrottling(latest: latest, gpuClockPeakMHz: gpuClockPeakMHz) }
    public var gpuClockDropFraction: Double { Self.gpuClockDropFraction(latest: latest, gpuClockPeakMHz: gpuClockPeakMHz) }
    public var cpuThrottling: Bool { Self.cpuThrottling(latest: latest, topology: topology) }
    public var cpuClockDropFraction: Double { Self.cpuClockDropFraction(latest: latest, topology: topology) }
    public var bandwidthCeilingGBs: Double { Self.bandwidthCeiling(topology: topology, bandwidthPeakGBs: bandwidthPeakGBs) }
    public var bottleneck: Bottleneck {
        Self.bottleneck(latest: latest, history: history, bandwidthPeakGBs: bandwidthPeakGBs, throttling: gpuThrottling)
    }
    public var memoryRisk: MemoryBudget.Risk {
        Self.memoryRisk(latest: latest, swapOutRate: memorySwapOutRate, compressionRate: memoryCompressionRate)
    }

    /// True when the GPU clock is held well below its rolling peak while the GPU is active and
    /// thermal pressure has risen above nominal — i.e. thermal throttling.
    /// Temperatures at which an Apple-Silicon die is worth a second look. One definition, used by
    /// the throttle detectors here and by the UI's temperature colours — two copies of a number
    /// like this drift, and then the app disagrees with itself about what "hot" means.
    ///
    /// These are not a linear share of anything: the die idles in the 40s and works comfortably
    /// into the 70s, so 80 °C is where a reading starts to mean something and 95 °C is where it is
    /// the story.
    public enum Thermal {
        public static let warnCelsius: Double = 80
        public static let criticalCelsius: Double = 95
    }

    /// The hottest CPU-side reading available. `cpuMaxCelsius` is the per-core maximum where the
    /// machine reports one; `cpuCelsius` is the average fallback.
    static func dieCelsius(_ s: SystemSnapshot) -> Double {
        max(s.temperature.cpuMaxCelsius, s.temperature.cpuCelsius)
    }

    /// True when the GPU's clock is held below its rolling peak **while the GPU is actually hot and
    /// doing work** — i.e. thermal throttling.
    ///
    /// ⚠️ The heat condition is the DIE TEMPERATURE, not `thermal.pressure` alone. Pressure is
    /// macOS's lagging aggregate: it stays `fair` for a while after a heavy run ends, with the fans
    /// still at 3400 rpm — and in that window the GPU has already dropped to its minimum clock
    /// because nothing is asking for performance. All three of the old conditions were then true
    /// and both cards outlined red on an idle machine.
    ///
    /// Measured, the two cases separate cleanly on temperature and not on utilisation: cooling-down
    /// read 63 % at 0.4 W and 57 °C, a genuine throttle read 97 % at 39 W and 100 °C. **Utilisation
    /// is not demand** — 0.4 W is not a GPU being held back — which is why the GPU's own reading is
    /// checked against power as well.
    ///
    /// Throttling is demand without response. The clock test is the missing response; heat and
    /// power are the demand.
    public static func gpuThrottling(latest: SystemSnapshot, gpuClockPeakMHz: Double) -> Bool {
        guard gpuClockPeakMHz > 0 else { return false }
        // The GPU sensor is absent on some machines — fall back to the die, which is still evidence
        // of heat, rather than silently never reporting a throttle there.
        let celsius = max(latest.temperature.gpuCelsius, dieCelsius(latest))
        return celsius >= Thermal.warnCelsius
            && latest.gpu.usage > 0.3
            && latest.power.gpuWatts > 1.0
            && latest.thermal.pressure != .nominal
            && latest.gpu.freqMHz < 0.85 * gpuClockPeakMHz
    }

    /// How far the current GPU clock sits below its rolling peak (0...1; 0 when at/above).
    public static func gpuClockDropFraction(latest: SystemSnapshot, gpuClockPeakMHz: Double) -> Double {
        guard gpuClockPeakMHz > 0, latest.gpu.freqMHz < gpuClockPeakMHz else { return 0 }
        return 1 - latest.gpu.freqMHz / gpuClockPeakMHz
    }

    /// True when the P-cluster clock is held well below the chip's top DVFS step while the P-cores are
    /// busy and thermal pressure has risen above nominal — i.e. CPU thermal throttling. Symmetric to
    /// gpuThrottling, but ceilinged on the per-chip DVFS max (topology.pFreqsMHz) rather than an
    /// observed peak, so the verdict is identical on live and replay (topology travels in the recording).
    public static func cpuThrottling(latest: SystemSnapshot, topology: CPUTopology?) -> Bool {
        guard let pMax = topology?.pFreqsMHz.max(), pMax > 0 else { return false }
        // Same correction as `gpuThrottling`: the die has to be hot, not merely to have been hot.
        // Cooling down after a run read 37 % busy at 60 °C; a genuine throttle read 41 % at 93 °C —
        // so utilisation cannot separate them and temperature can. Power is not used here: the
        // P-cluster rail spikes on short bursts and reads high on an otherwise idle machine.
        return dieCelsius(latest) >= Thermal.warnCelsius
            && latest.cpu.pUsage > 0.3
            && latest.thermal.pressure != .nominal
            && latest.cpu.pFreqMHz < 0.85 * pMax
    }

    /// How far the current P-cluster clock sits below the chip's top DVFS step (0...1; 0 when at/above).
    public static func cpuClockDropFraction(latest: SystemSnapshot, topology: CPUTopology?) -> Double {
        guard let pMax = topology?.pFreqsMHz.max(), pMax > 0, latest.cpu.pFreqMHz < pMax else { return 0 }
        return 1 - latest.cpu.pFreqMHz / pMax
    }

    /// Unified-memory bandwidth ceiling (GB/s): the per-chip spec value, raised to the observed
    /// peak if traffic ever exceeds it (so it never under-reports and works on unlisted chips).
    public static func bandwidthCeiling(topology: CPUTopology?, bandwidthPeakGBs: Double) -> Double {
        let spec = topology.map { Bottleneck.bandwidthCeilingGBs(chipName: $0.chipName, pCoreCount: $0.pCoreCount) } ?? 0
        return max(spec, bandwidthPeakGBs)
    }

    /// The single dominant AI-workload bottleneck. Classified on a short rolling average of GPU%
    /// and bandwidth so the verdict doesn't flicker sample-to-sample.
    public static func bottleneck(latest: SystemSnapshot, history: History,
                                  bandwidthPeakGBs: Double, throttling: Bool) -> Bottleneck {
        Bottleneck.classify(memoryCritical: latest.memory.pressure == .critical,
                            gpuUsage: tailAverage(history.gpu, count: 3, fallback: latest.gpu.usage),
                            bandwidthGBs: tailAverage(history.bandwidth, count: 3, fallback: latest.bandwidth.totalGBs),
                            achievableGBs: bandwidthPeakGBs,
                            throttling: throttling)
    }

    /// Refined memory risk: the static budget baseline plus swap/compression rates.
    public static func memoryRisk(latest: SystemSnapshot, swapOutRate: Double,
                                  compressionRate: Double) -> MemoryBudget.Risk {
        let base = latest.memoryBudget.risk
        if base == .swapping || swapOutRate > 0 { return .swapping }
        if compressionRate > compressionRatePagesPerSec && latest.memoryBudget.headroomNowBytes < (1 << 30) {
            return .tight
        }
        return base
    }

    /// Mean of the last `count` REAL samples. Gaps are dropped rather than averaged: one `.nan`
    /// in the tail would otherwise make the whole average NaN, and every comparison against it
    /// false — a bottleneck verdict that silently answers "no" to everything.
    private static func tailAverage(_ values: [Double], count: Int, fallback: Double) -> Double {
        let tail = values.suffix(count).withoutGaps
        return tail.isEmpty ? fallback : tail.reduce(0, +) / Double(tail.count)
    }

    private func updateMemoryRates(_ m: MemorySample, dt: TimeInterval) {
        let cur = MemCounters(pageins: m.pageins, pageouts: m.pageouts, swapins: m.swapins,
                              swapouts: m.swapouts, compressions: m.compressions)
        defer { previousMem = cur }
        guard let prev = previousMem, dt > 0 else { resetRatesOnly(); return }
        func delta(_ now: UInt64, _ was: UInt64) -> Double { now >= was ? Double(now - was) : 0 }
        memoryPageInRate = delta(cur.pageins, prev.pageins) / dt
        memoryPageOutRate = delta(cur.pageouts, prev.pageouts) / dt
        memorySwapInRate = delta(cur.swapins, prev.swapins) / dt
        // Only swapouts (eviction under pressure) signal a problem; swapins are recovery reads
        // of pages swapped earlier and must NOT trip the "swapping" warning.
        memorySwapOutRate = delta(cur.swapouts, prev.swapouts) / dt
        memoryCompressionRate = delta(cur.compressions, prev.compressions) / dt
    }

    /// Zeros the rates without touching previousMem (the caller's defer sets it).
    private func resetRatesOnly() {
        memoryPageInRate = 0; memoryPageOutRate = 0
        memorySwapInRate = 0; memorySwapOutRate = 0; memoryCompressionRate = 0
    }
}
