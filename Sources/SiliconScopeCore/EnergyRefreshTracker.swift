//
//  File:      EnergyRefreshTracker.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Turns cumulative energy counters into honest wattages however often the OS updates
//             them (#65). Pure: it is fed (counter values, time) pairs in order and never touches
//             IOReport itself.
//  Notes:     Three update regimes exist on macOS 27.0 (26A428), and they differ by CHIP:
//
//               live     every read              macOS ≤ 26
//               batched  every ~2.1 s            M5 Max (all-smi #410: once per 18–19 reads at
//                                                ~117 ms, under an 8-thread load)
//               slow     every ~30 min           M1 Max, measured here: the Energy Model rails
//                                                refresh when PerfPowerServices takes its periodic
//                                                snapshot ("Received SBC notification", 1800–1861 s
//                                                apart all day), and one refresh landed as TWO
//                                                pieces 2 s apart — a large jump, then a residual
//                                                of +76 mJ on CPU Energy
//
//             Fed through a fixed per-tick delta, "slow" reads 0 W nearly always (what #65 reports)
//             and "batched" alternates 0 W with double values (what #410 reports).
//
//             The slow refreshes are driven by power-management EVENTS, not by a clock: besides
//             powerlog's ~30-minute snapshot, every display on/off moved the counters within a
//             second (19:38:01 off → 19:38:02, 19:48:46 on → 19:48:47, 19:49:16 off → 19:49:17 …).
//             Nothing sudoless can request one.
//
//             ⚠️ "batched" and "slow" look alike at first: a slow refresh arrives in pieces a few
//             seconds apart (two pieces 2 s apart at 18:53; THREE pieces at 0, +1 and +3 s when the
//             display woke at 19:48), and a batch counter moves every ~2 s. What separates them is
//             DURATION — a refresh's pieces end within seconds and silence follows; batching never
//             stops. So a run counts as batching only once it has kept going past `runGap`, and
//             nothing is published from inside a run until then. A rule on the NUMBER of changes
//             was tried and failed on the real three-piece refresh: it read 7.6 W for a machine whose
//             measured average was 2.4 W, for the ten seconds right after the screen came on.
//
import Foundation

public struct EnergyRefreshTracker: Sendable {

    /// What a caller should publish for the rails this tick.
    public enum Reading: Equatable, Sendable {
        /// Fresh on every read: energy per rail over the slice, and the slice's length.
        case live(energy: [String: Int], seconds: Double)
        /// Energy per rail over a measured span between counter updates, and that span's length.
        /// Seconds long for batched counters, tens of minutes for slow ones.
        case averaged(energy: [String: Int], seconds: Double)
        /// No complete, well-timed span yet. The wattage is unknown — never zero.
        case pending
    }

    /// How many recent slices decide whether the counters are live. A live counter moves in every
    /// slice (a running CPU always consumes energy); anything else fails this within three reads.
    static let regimeSlices = 3

    /// The largest gap between two reads across which a change's time still counts as known.
    /// A longer gap — sampling paused while nothing on screen needed power (#13) — hides when the
    /// counters moved, so a change seen across it restarts the chain instead of anchoring a span.
    static let maxTimingUncertainty: Double = 5

    /// Changes closer than this belong to the same run. Five times the measured split of a slow
    /// refresh (2 s) and a hundred-and-eightieth of the gap between slow refreshes (≥ 1800 s);
    /// batches (~2.1 s apart) fall inside it, which is how they are recognised as a run.
    static let runGap: Double = 10

    /// A run that has lasted this long is batching, not one refresh arriving in pieces: the pieces
    /// of every refresh observed ended within 3 s. Equal to `runGap` on purpose — a run still going
    /// after the time in which a refresh would have settled cannot be a refresh.
    static let batchRunDuration: Double = runGap

    /// How far back a batched reading reaches. Each change's time is known to half a read gap
    /// (~0.4 s); over ~10 s that is a few percent, where a single ~2 s batch would carry ±20 %.
    static let batchSpan: Double = 10

    private var recentSliceMoved: [Bool] = []
    private var lastRead: (values: [String: Int], time: Double)?

    // The current run of changes, oldest first, and whether its first change was well timed.
    private var run: [(values: [String: Int], time: Double)] = []
    private var runTimed = false

    // Settled refreshes (slow regime). Only timed ones anchor a span.
    private var older: (values: [String: Int], time: Double)?
    private var newer: (values: [String: Int], time: Double)?

    public init() {}

    /// Feed one sampling call: the counters read at `ta` and again at `tb` (seconds, any epoch,
    /// increasing). Values are the rails' cumulative counters, keyed by rail name.
    public mutating func observe(_ a: [String: Int], at ta: Double,
                                 _ b: [String: Int], at tb: Double) -> Reading {
        recentSliceMoved.append(Self.total(b) != Self.total(a))
        if recentSliceMoved.count > Self.regimeSlices { recentSliceMoved.removeFirst() }

        track(a, at: ta)
        track(b, at: tb)

        guard recentSliceMoved.count == Self.regimeSlices else { return .pending }
        if recentSliceMoved.allSatisfy({ $0 }) {
            return .live(energy: Self.delta(from: a, to: b), seconds: max(tb - ta, 0.001))
        }
        if isBatching, let last = run.last {
            // Batched: span back from the latest change to the latest one at least `batchSpan`
            // earlier (or to the run's start while the run is still shorter than that).
            let from = run.last(where: { last.time - $0.time >= Self.batchSpan }) ?? run[0]
            return .averaged(energy: Self.delta(from: from.values, to: last.values),
                             seconds: last.time - from.time)
        }
        guard let o = older, let n = newer, n.time > o.time else { return .pending }
        return .averaged(energy: Self.delta(from: o.values, to: n.values), seconds: n.time - o.time)
    }

    /// Advances the bookkeeping by one read.
    private mutating func track(_ values: [String: Int], at t: Double) {
        defer { lastRead = (values, t) }
        guard let prev = lastRead else { return }          // first read ever: a value, not a change

        let wellTimed = t - prev.time <= Self.maxTimingUncertainty
        // The counters moved somewhere between the two reads; the midpoint halves the error of
        // pinning it to either end.
        let changeTime = (prev.time + t) / 2

        if Self.total(values) != Self.total(prev.values) {
            if let last = run.last, wellTimed, changeTime - last.time < Self.runGap {
                run.append((values, changeTime))
                if run.count > 64 { run.removeFirst(run.count - 64) }   // batching runs forever
            } else {
                closeRun()
                run = [(values, changeTime)]
                runTimed = wellTimed
            }
        } else if let last = run.last, !wellTimed || t - last.time >= Self.runGap {
            closeRun()
        }
    }

    /// The current run has gone on longer than any refresh's pieces do.
    private var isBatching: Bool {
        guard let first = run.first, let last = run.last else { return false }
        return last.time - first.time >= Self.batchRunDuration
    }

    /// Settles a finished run. A short run is ONE refresh arriving in pieces (its moment is the
    /// first piece, its value the last). A run that was batching has stopped — its last change is a
    /// refresh like any other, so a slow chain can continue from it.
    private mutating func closeRun() {
        guard let first = run.first, let last = run.last else { return }
        let refresh = isBatching ? last : (values: last.values, time: first.time)
        run = []
        if runTimed {
            older = newer
            newer = refresh
        } else {
            // Its value is real but its moment is not, so no span may begin or end on it. The chain
            // restarts: two further timed refreshes are needed before anything is published.
            older = nil
            newer = nil
        }
    }

    private static func total(_ v: [String: Int]) -> Int { v.values.reduce(0, &+) }

    private static func delta(from a: [String: Int], to b: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, vb) in b { out[k] = vb &- (a[k] ?? vb) }
        return out
    }
}
