//
//  File:      EnergyRefreshTrackerTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in how cumulative energy counters become watts on both kinds of OS (#65):
//             counters that move on every read (macOS ≤ 26) and counters that refresh every few
//             minutes (macOS 27).
//  Notes:     The slow-refresh scenarios replay what an M1 Max on macOS 27.0 actually did: flat for
//             ~300 s, then one refresh arriving as two bursts 2 s apart (a large jump, then a
//             residual of +76 mJ). Reads follow the sampler's real rhythm — a pair 0.2 s apart,
//             once per 1 s tick.
//
import XCTest
@testable import SiliconScopeCore

final class EnergyRefreshTrackerTests: XCTestCase {

    /// Drives the tracker with the sampler's rhythm: per tick, reads at t and t + 0.2.
    private struct Rig {
        var tracker = EnergyRefreshTracker()
        var t: Double = 0
        mutating func tick(_ counter: (Double) -> Int, every seconds: Double = 1) -> EnergyRefreshTracker.Reading {
            let a = ["CPU Energy": counter(t)]
            let b = ["CPU Energy": counter(t + 0.2)]
            let r = tracker.observe(a, at: t, b, at: t + 0.2)
            t += seconds
            return r
        }
    }

    // MARK: - Live counters (macOS ≤ 26)

    /// 5 W of CPU, read fresh every time: the slice delta, exactly as before.
    func testALiveCounterIsReadPerSlice() {
        var rig = Rig()
        let fiveWatts: (Double) -> Int = { Int($0 * 5_000) }       // mJ
        var last = EnergyRefreshTracker.Reading.pending
        for _ in 0..<5 { last = rig.tick(fiveWatts) }
        guard case .live(let e, let s) = last else { return XCTFail("expected live, got \(last)") }
        XCTAssertEqual(Double(e["CPU Energy"]!) / s / 1000, 5, accuracy: 0.05)
    }

    /// The regime needs a few slices to be sure. Until then the honest answer is "not yet".
    func testTheFirstTicksArePendingRatherThanZero() {
        var rig = Rig()
        XCTAssertEqual(rig.tick { Int($0 * 5_000) }, .pending)
        XCTAssertEqual(rig.tick { Int($0 * 5_000) }, .pending)
    }

    // MARK: - Slow counters (macOS 27)

    /// The measured macOS 27 shape: 5 W accrued, published only at refreshes 300 s apart, each
    /// delivered as a jump plus a small residual 2 s later.
    private func slow(refreshEvery period: Double = 300, watts: Double = 5) -> (Double) -> Int {
        { t in
            let n = floor(t / period)                              // refreshes completed so far
            let base = n * period * watts * 1000                   // mJ published at the last refresh
            let sinceRefresh = t - n * period
            // The residual (+76 mJ) lands 2 s after each refresh — held back until then.
            let residual = (n > 0 && sinceRefresh < 2) ? -76.0 : 0
            return Int(base + residual)
        }
    }

    /// ⚠️ #65 itself. Between refreshes every slice is flat; the old per-tick delta published 0 W
    /// here. The tracker must say "unknown" until it has a window, then the window's true average.
    func testASlowCounterIsNeverPublishedAsZero() {
        var rig = Rig()
        for i in 0..<250 {
            let r = rig.tick(slow())
            if i >= 3 { XCTAssertEqual(r, .pending, "tick \(i): no complete window yet") }
        }
    }

    func testASlowCounterReportsTheTrueAverageBetweenRefreshes() {
        var rig = Rig()
        var last = EnergyRefreshTracker.Reading.pending
        for _ in 0..<(300 * 3 + 20) { last = rig.tick(slow()) }
        guard case .averaged(let e, let s) = last else { return XCTFail("expected averaged, got \(last)") }
        XCTAssertEqual(s, 300, accuracy: 1.5, "the window is the span between refreshes")
        XCTAssertEqual(Double(e["CPU Energy"]!) / s / 1000, 5, accuracy: 0.05)
    }

    /// ⚠️ The split refresh. Treating the 2 s-later residual as a refresh of its own produces a 2 s
    /// window containing 76 mJ — 38 mW for a machine drawing 5 W.
    func testATwoPieceRefreshIsOneRefresh() {
        var rig = Rig()
        for _ in 0..<(300 * 3 + 20) {
            if case .averaged(let e, let s) = rig.tick(slow()) {
                XCTAssertGreaterThan(s, 250, "a residual must not open a window of its own")
                XCTAssertGreaterThan(Double(e["CPU Energy"]!) / s / 1000, 4)
            }
        }
    }

    /// ⚠️ The spike. A refresh that lands inside a 0.2 s slice carries minutes of energy; divided
    /// by the slice it read as hundreds of watts. It must be read as a refresh, not as a slice.
    func testARefreshInsideASliceIsNotASpike() {
        var rig = Rig()
        for _ in 0..<(300 * 4) {
            switch rig.tick(slow()) {
            case .live(let e, let s):
                XCTFail("a slow counter was read live: \(Double(e["CPU Energy"]!) / s / 1000) W")
            case .averaged(let e, let s):
                XCTAssertLessThan(Double(e["CPU Energy"]!) / s / 1000, 6)
            case .pending: break
            }
        }
    }

    /// Sampling paused (#13 — nothing on screen needed power) across a refresh. That refresh's
    /// moment is unknown, so it cannot anchor a window; the tracker starts over instead of
    /// averaging over a span it would misstate.
    func testARefreshSeenOnlyAfterALongPauseRestartsTheChain() {
        var rig = Rig()
        for _ in 0..<(300 * 3 + 20) { _ = rig.tick(slow()) }
        // Pause 500 s, crossing at least one refresh, then resume.
        rig.t += 500
        var sawPending = false
        for _ in 0..<60 { if rig.tick(slow()) == .pending { sawPending = true } }
        XCTAssertTrue(sawPending, "after an untimed refresh the average must be withheld, not guessed")
        // Two further timed refreshes restore it, and it is right again.
        var last = EnergyRefreshTracker.Reading.pending
        for _ in 0..<(300 * 2 + 20) { last = rig.tick(slow()) }
        guard case .averaged(let e, let s) = last else { return XCTFail("expected averaged, got \(last)") }
        XCTAssertEqual(Double(e["CPU Energy"]!) / s / 1000, 5, accuracy: 0.05)
    }

    /// A busier machine reads higher — the tracker reports the counter, it does not smooth it into
    /// a constant.
    func testTheAverageFollowsTheLoad() {
        var rig = Rig()
        var last = EnergyRefreshTracker.Reading.pending
        for _ in 0..<(300 * 3 + 20) { last = rig.tick(slow(watts: 22)) }
        guard case .averaged(let e, let s) = last else { return XCTFail("expected averaged") }
        XCTAssertEqual(Double(e["CPU Energy"]!) / s / 1000, 22, accuracy: 0.2)
    }
}

/// The M5 Max shape on the same macOS 27.0 build (all-smi #410): the mJ rails move in batches
/// ~2.1 s apart. A fixed 1 s window alternated 0 W with ~double values there; this regime must read
/// steadily and near-live, and — the reason this suite exists at all — it must not be mistaken for
/// a slow refresh's two pieces and left pending forever.
final class BatchedEnergyCounterTests: XCTestCase {

    private func batched(watts: Double, every period: Double = 2.1) -> (Double) -> Int {
        { t in Int(floor(t / period) * period * watts * 1000) }
    }

    private func run(_ counter: (Double) -> Int, seconds: Int) -> [EnergyRefreshTracker.Reading] {
        var tracker = EnergyRefreshTracker()
        var out: [EnergyRefreshTracker.Reading] = []
        var t = 0.0
        for _ in 0..<seconds {
            out.append(tracker.observe(["CPU Energy": counter(t)], at: t, ["CPU Energy": counter(t + 0.2)], at: t + 0.2))
            t += 1
        }
        return out
    }

    private func watts(_ r: EnergyRefreshTracker.Reading) -> Double? {
        if case .averaged(let e, let s) = r { return Double(e["CPU Energy"]!) / s / 1000 }
        if case .live(let e, let s) = r { return Double(e["CPU Energy"]!) / s / 1000 }
        return nil
    }

    func testBatchedCountersAreReadWithinSeconds() {
        let readings = run(batched(watts: 34), seconds: 30)
        let firstKnown = readings.firstIndex { watts($0) != nil }
        XCTAssertNotNil(firstKnown)
        // Batching is only declared once a run outlasts `runGap` (10 s) — the price of never
        // mistaking a slow refresh's pieces for it. Seconds, not the half hour a slow refresh takes.
        XCTAssertLessThanOrEqual(firstKnown ?? 99, 15, "a batching M5 must not wait for a slow refresh")
    }

    /// #410's symptom was 0.00, 36.17, 0.00, 33.25 … Once known, every tick must be near the truth.
    func testBatchedCountersReadSteadilyAndNeverZero() {
        for (i, r) in run(batched(watts: 34), seconds: 120).enumerated() where i >= 15 {
            guard let w = watts(r) else { return XCTFail("tick \(i) fell back to pending") }
            XCTAssertEqual(w, 34, accuracy: 34 * 0.15, "tick \(i)")
        }
    }

    /// The span a batched reading covers is short enough to present as live.
    func testABatchedSpanIsPresentedAsLive() {
        guard case .averaged(_, let s) = run(batched(watts: 34), seconds: 60).last! else {
            return XCTFail("expected a batched span")
        }
        var p = PowerSample()
        p.railWindowSeconds = s
        XCTAssertFalse(p.railsAveraged, "a \(s) s span must not be labelled as an average")
        XCTAssertTrue(p.railsKnown)
    }
}

/// Replays the refresh an M1 Max on macOS 27.0 delivered when its display woke at 19:48:46: three
/// pieces at +0, +1 and +3 s (+1,522,252 / +14,828 / +7,977 mJ), after 645 s of silence that
/// averaged 2.36 W. A rule that called three changes "batching" read that as ~7.6 W for ten
/// seconds — right as the screen came on.
final class ThreePieceRefreshTests: XCTestCase {

    func testAThreePieceRefreshIsOneRefreshAndNeverAShortWindow() {
        // Counter: an earlier refresh at t=100, then silence, then the three-piece refresh at t=745.
        func counter(_ t: Double) -> Int {
            var v = 1_000_000
            if t >= 100 { v += 500_000 }
            if t >= 745 { v += 1_522_252 }
            if t >= 746 { v += 14_828 }
            if t >= 748 { v += 7_977 }
            return v
        }
        var tracker = EnergyRefreshTracker()
        var t = 0.0
        while t < 820 {
            let r = tracker.observe(["CPU Energy": counter(t)], at: t, ["CPU Energy": counter(t + 0.2)], at: t + 0.2)
            if case .averaged(let e, let s) = r {
                XCTAssertGreaterThan(s, 600, "t=\(t): published a \(s) s span from inside a refresh")
                let w = Double(e["CPU Energy"]!) / s / 1000
                XCTAssertEqual(w, 1_545_057.0 / 645 / 1000, accuracy: 0.1, "t=\(t)")
            }
            if case .live = r { XCTFail("t=\(t): a slow counter was read live") }
            t += 1
        }
    }
}
