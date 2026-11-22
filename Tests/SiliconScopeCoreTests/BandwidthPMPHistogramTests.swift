//
//  File:      BandwidthPMPHistogramTests.swift
//  Created:   2026-07-15
//  Updated:   2026-11-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for the PMP "DCS BW" histogram fallback path in BandwidthSampler —
//             the residency-weighted-average math, the "NGB/s" state-name parser, requestor
//             classification, and aggregate-only AMCC fallback, one die or two, with its
//             lowest band treated as a bound rather than a reading.
//  Notes:     No hardware: these are pure functions over explicit inputs. Fixtures come from
//             M4/M5 Max macOS 26.5.2 per-requestor histograms, the M3 Max macOS 27
//             aggregate-only histogram documented in docs/ioreport-channels.md, and an M3 Ultra
//             macOS 27.2.1 (#93) with one AMCC per die, idle and under a 733 GB/s GPU stream.
//
import XCTest
@testable import SiliconScopeCore

final class BandwidthPMPHistogramTests: XCTestCase {

    // MARK: - "NGB/s" state-name parsing

    func testParseHistogramBucketGBs() {
        XCTAssertEqual(BandwidthSampler.parseHistogramBucketGBs("   1GB/s"), 1)
        XCTAssertEqual(BandwidthSampler.parseHistogramBucketGBs("  32GB/s"), 32)
        XCTAssertEqual(BandwidthSampler.parseHistogramBucketGBs("9GB/s"), 9)
        XCTAssertEqual(BandwidthSampler.parseHistogramBucketGBs("  12gb/s"), 12, "case-insensitive")
    }

    func testParseHistogramBucketGBsRejectsUnrelatedNames() {
        XCTAssertNil(BandwidthSampler.parseHistogramBucketGBs("IDLE"))
        XCTAssertNil(BandwidthSampler.parseHistogramBucketGBs("F1"))
        XCTAssertNil(BandwidthSampler.parseHistogramBucketGBs(""))
        XCTAssertNil(BandwidthSampler.parseHistogramBucketGBs("32GB"))
    }

    // MARK: - Residency-weighted average (same idiom as CPUSampler's DVFS frequency weighting)

    func testWeightedAverageGBsAllResidencyInOneBucket() {
        let value = BandwidthSampler.weightedAverageGBs([(gbs: 5, residency: 100)])
        XCTAssertEqual(value, 5, accuracy: 0.0001)
    }

    func testWeightedAverageGBsAcrossBuckets() {
        // Matches this project's own captured fixture (EACC0, PMP "DCS BW", under moderate
        // CPU traffic): mostly low buckets with a long, thin tail.
        let buckets: [(gbs: Double, residency: UInt64)] = [
            (1, 338), (2, 54), (3, 49), (4, 34), (5, 21), (6, 19), (7, 5), (8, 4), (9, 1),
        ]
        let value = BandwidthSampler.weightedAverageGBs(buckets)
        XCTAssertEqual(value, 1.95, accuracy: 0.01)
    }

    func testWeightedAverageGBsEmptyIsZero() {
        XCTAssertEqual(BandwidthSampler.weightedAverageGBs([]), 0)
    }

    func testWeightedAverageGBsAllZeroResidencyIsZero() {
        let buckets: [(gbs: Double, residency: UInt64)] = [(1, 0), (2, 0), (32, 0)]
        XCTAssertEqual(BandwidthSampler.weightedAverageGBs(buckets), 0)
    }

    func testWeightedAverageGBsReflectsHeavyTopBucketResidency() {
        // Matches this project's own captured fixture (AGX/GPU, PMP "DCS BW", under a sustained
        // GPU compute workload): most residency sits in the low buckets, but a sizeable share (21
        // of 379 ticks) sits in the top ("32GB/s") bucket — very likely a saturating/clamped bin
        // rather than a literal ceiling (see BandwidthSampler's file header). Expected value
        // (Σ residency·GBs / Σ residency = 1419/379) hand-verified against this fixture.
        let buckets: [(gbs: Double, residency: UInt64)] = [
            (1, 319), (2, 16), (3, 4), (7, 1), (11, 1), (16, 2), (18, 3), (19, 1), (20, 2),
            (21, 3), (22, 2), (26, 1), (29, 2), (30, 1), (32, 21),
        ]
        let value = BandwidthSampler.weightedAverageGBs(buckets)
        XCTAssertEqual(value, 3.744, accuracy: 0.001)
        // And it's well above what the low buckets alone would give (~1.06 avg for the first
        // three buckets), showing the top-bucket residency meaningfully pulls the average up.
        let lowBucketsOnly = BandwidthSampler.weightedAverageGBs([(1, 319), (2, 16), (3, 4)])
        XCTAssertGreaterThan(value, lowBucketsOnly)
    }

    // MARK: - PMP-histogram requestor → bucket map (distinct spellings from the classic map)

    func testClassifyPMPHistogramRequestor() {
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("EACC0"), .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("PACC0"), .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("PACC1"), .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("AGX"),   .gpu)
        for media in ["ISP0", "JPEG0", "PRORES1", "SCODEC0", "AVE0", "AVE1", "AVD0"] {
            XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor(media), .media, media)
        }
        // The ANE has its own lane (it used to fold into other, hiding a WhisperKit run's ~19 GB/s
        // there). Fabric/coherency and display requestors still have no bucket and fold into other,
        // matching the classic path's MSR/DISP/ANS handling.
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("ANE0"), .ane)
        for other in ["ANS", "ATC0", "ATC3", "DISPEXT0", "DISPINT", "MSR0", "MSR1", "AMCC"] {
            XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor(other), .other, other)
        }
        // The per-requestor classifier never returns .total; AMCC is handled separately.
        XCTAssertNotEqual(BandwidthSampler.classifyPMPHistogramRequestor("EACC0"), .total)
    }

    // MARK: - M5 Max PMP-histogram requestor names (github.com/kennss/SiliconScope#30)

    func testClassifyPMPHistogramRequestorM5MaxNames() {
        // M5 Max ("PMP0" / "DCS BW") CPU clusters are "MACC*" (were "EACC*"/"PACC*" on M1–M4).
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("MACC0"), .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("MACC1"), .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("PACC"),  .cpu)
        XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor("AGX"),   .gpu)
        // Video engines on M5 are "AVD"/"AVE"; "SCODEC"/"PRORES"/"ISP" unchanged.
        for media in ["AVD", "SCODEC", "SCODEC RT", "PRORES", "ISP", "ISP RT"] {
            XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor(media), .media, media)
        }
        // M5 names its ANE lanes "ANE L0"/"ANE L1" (was "ANE0") — both are the ANE lane.
        for ane in ["ANE L0", "ANE L1"] {
            XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor(ane), .ane, ane)
        }
        for other in ["MSR0", "MSR1", "DISPINT", "DISPEXT0"] {
            XCTAssertEqual(BandwidthSampler.classifyPMPHistogramRequestor(other), .other, other)
        }
    }

    // MARK: - AMCC aggregate handling (github.com/kennss/SiliconScope#30/#46)

    func testPMPHistogramRecognizesAMCCAggregateNotMACC() {
        XCTAssertTrue(BandwidthSampler.isPMPHistogramAggregate("AMCC"))
        XCTAssertTrue(BandwidthSampler.isPMPHistogramAggregate("AMCC0"))
        // The M5 CPU cluster "MACC*" must not be mistaken for the AMCC aggregate.
        XCTAssertFalse(BandwidthSampler.isPMPHistogramAggregate("MACC0"))
        XCTAssertFalse(BandwidthSampler.isPMPHistogramAggregate("MACC1"))
        XCTAssertFalse(BandwidthSampler.isPMPHistogramAggregate("AGX"))
        XCTAssertFalse(BandwidthSampler.isPMPHistogramAggregate("PACC"))
    }

    private func reading(_ gbs: Double, floor: Double = 0) -> BandwidthSampler.HistogramReading {
        BandwidthSampler.HistogramReading(gbs: gbs, floorGBs: floor)
    }

    func testPMPHistogramUsesSoleAMCCAsMeasuredTotal() {
        // Live M3 Max/macOS 27 fixture: PMP0/DCS BW exposes only AMCC while GPU is loaded.
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", reading(278.695))], perRequestorChannelCount: 0)
        XCTAssertEqual(r.total ?? -1, 278.695, accuracy: 0.001)
        XCTAssertNil(r.below)
    }

    func testPMPHistogramIgnoresAMCCBesidePerRequestorChannels() {
        // M5 Max: one AMCC beside the lanes. It sits on its floor near idle and is unchecked
        // against a timed load, so the lanes stay the reading (unchanged by #95).
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", reading(40.1))], perRequestorChannelCount: 20)
        XCTAssertNil(r.total)
        XCTAssertNil(r.below, "the lanes carry the total there; no bound either")
    }

    func testPMPHistogramRejectsMissingOrAmbiguousAggregate() {
        XCTAssertNil(BandwidthSampler.pmpAggregateTotal([], perRequestorChannelCount: 0).total)
        // Two aggregates in ONE group: nothing says how they compose.
        let twoInOne = BandwidthSampler.pmpAggregateTotal(
            [("PMP0", reading(100)), ("PMP0", reading(100))], perRequestorChannelCount: 0)
        XCTAssertNil(twoInOne.total)
        XCTAssertNil(twoInOne.below)
    }

    // MARK: - M3 Ultra: one AMCC per die (github.com/kennss/SiliconScope#93)

    /// The live histograms from the Ultra under a Metal kernel the GPU timed at 733 GB/s.
    private let ultraAMCC0: [(gbs: Double, residency: UInt64)] =
        [(64, 47), (128, 34), (192, 37), (256, 32), (320, 373), (384, 3925)]
    private let ultraAMCC1: [(gbs: Double, residency: UInt64)] =
        [(64, 12), (128, 14), (192, 16), (256, 11), (320, 23), (384, 742)]

    func testUltraDiesAddUpToTheTrafficTheGPUTimed() {
        let die0 = BandwidthSampler.histogramReading(ultraAMCC0)
        let die1 = BandwidthSampler.histogramReading(ultraAMCC1)
        XCTAssertEqual(die0.gbs, 370.8, accuracy: 0.05)
        XCTAssertEqual(die1.gbs, 367.6, accuracy: 0.05)
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", die0), ("PMP1", die1)], perRequestorChannelCount: 0)
        XCTAssertEqual(r.total ?? -1, 738.4, accuracy: 0.1, "both dies, not the first one alone (~370)")
        XCTAssertNil(r.below)
    }

    /// Idle, all residency sat in the 64 GB/s band on each die: that is a bound, not 64 or 128.
    func testUltraIdleIsABoundNotAReading() {
        let idle: [(gbs: Double, residency: UInt64)] = [(64, 897), (128, 0), (192, 0), (384, 0)]
        let die = BandwidthSampler.histogramReading(idle)
        XCTAssertTrue(die.isBound)
        XCTAssertEqual(die.floorGBs, 64)
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", die), ("PMP1", die)], perRequestorChannelCount: 0)
        XCTAssertNil(r.total)
        XCTAssertEqual(r.below ?? -1, 128)
    }

    /// One die busy, one idle: the busy one is a reading, so the sum is an estimate, not a bound.
    func testOneBusyDieMakesItAReading() {
        let busy = BandwidthSampler.histogramReading(ultraAMCC0)
        let idle = BandwidthSampler.histogramReading([(64, 897), (128, 0)])
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", busy), ("PMP1", idle)], perRequestorChannelCount: 0)
        XCTAssertEqual(r.total ?? -1, 370.8 + 64, accuracy: 0.1)
        XCTAssertNil(r.below)
    }

    // MARK: - M5 Ultra: AMCC per die beside lanes that miss the traffic (github.com/kennss/SiliconScope#95)

    /// The live histograms from an M5 Ultra (Mac17,15) under a GPU kernel that timed itself
    /// moving 1091.3 GB/s; meanwhile AGX sat wholly in its 1 GB/s band.
    private let m5UltraAMCC0: [(gbs: Double, residency: UInt64)] =
        [(64, 1), (128, 7), (192, 11), (256, 4), (320, 8), (384, 5), (448, 8), (512, 307), (576, 620)]
    private let m5UltraAMCC1: [(gbs: Double, residency: UInt64)] =
        [(64, 5), (128, 4), (192, 12), (256, 5), (320, 7), (384, 4), (448, 9), (512, 568), (576, 353)]

    func testM5UltraDiesAreTheTotalEvenBesideRequestorLanes() {
        let die0 = BandwidthSampler.histogramReading(m5UltraAMCC0)
        let die1 = BandwidthSampler.histogramReading(m5UltraAMCC1)
        XCTAssertEqual(die0.gbs, 542.187, accuracy: 0.01)
        XCTAssertEqual(die1.gbs, 523.648, accuracy: 0.01)
        // 37 DCS BW requestors in the dump, 2 of them the AMCCs.
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", die0), ("PMP1", die1)], perRequestorChannelCount: 35)
        XCTAssertEqual(r.total ?? -1, 1065.8, accuracy: 0.1, "not the ~13 GB/s the lanes summed to")
        XCTAssertNil(r.below)
    }

    /// Idle, both M5 Ultra AMCCs sat in their 64 GB/s band: a bound even with lanes beside them.
    func testM5UltraIdleIsABoundBesideLanes() {
        let idle = BandwidthSampler.histogramReading([(64, 970), (128, 0), (576, 0)])
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", idle), ("PMP1", idle)], perRequestorChannelCount: 35)
        XCTAssertNil(r.total)
        XCTAssertEqual(r.below ?? -1, 128)
    }

    /// #95 rerun on main: idle, each M5 Ultra die put 2 samples in its 128 GB/s band and the
    /// rest in its 64 GB/s floor. That flipped the old wholly-in-floor rule and showed
    /// "128 GB/s" as if measured; nearly all of it is the floor, so it stays a bound.
    func testM5UltraIdleBurstsStayABound() {
        let die0 = BandwidthSampler.histogramReading([(64, 986), (128, 2)])
        let die1 = BandwidthSampler.histogramReading([(64, 391), (128, 2)])
        XCTAssertEqual(die0.gbs, 64.130, accuracy: 0.001)
        XCTAssertEqual(die1.gbs, 64.326, accuracy: 0.001)
        XCTAssertTrue(die0.isBound && die1.isBound)
        let r = BandwidthSampler.pmpAggregateTotal([("PMP0", die0), ("PMP1", die1)], perRequestorChannelCount: 35)
        XCTAssertNil(r.total)
        XCTAssertEqual(r.below ?? -1, 128.456, accuracy: 0.001)
        // GPU compute (no memory stream) in the same rerun: more bursts, still mostly floor.
        let gpu0 = BandwidthSampler.histogramReading([(64, 935), (128, 18)])
        let gpu1 = BandwidthSampler.histogramReading([(64, 935), (128, 15), (192, 4)])
        XCTAssertNil(BandwidthSampler.pmpAggregateTotal([("PMP0", gpu0), ("PMP1", gpu1)], perRequestorChannelCount: 35).total)
    }

    func testHistogramBoundRule() {
        XCTAssertFalse(BandwidthSampler.histogramReading([(64, 0), (128, 0)]).isBound, "no residency at all")
        XCTAssertTrue(BandwidthSampler.histogramReading([(64, 5), (128, 1)]).isBound, "53 of its 75 GB/s is floor")
        XCTAssertFalse(BandwidthSampler.histogramReading([(64, 1), (128, 5)]).isBound, "11 of its 117 GB/s is floor")
        XCTAssertFalse(BandwidthSampler.histogramReading([(0, 5), (64, 0)]).isBound, "a 0 band is a real reading")
        XCTAssertFalse(BandwidthSampler.histogramReading([(0, 5), (64, 1)]).isBound, "a 0 floor adds nothing unmeasured")
    }

    // MARK: - What the total looks like as text

    func testTotalTextShowsTheBound() {
        var s = BandwidthSample()
        s.belowGBs = 128
        XCTAssertEqual(s.totalGBs, 0, "math sees a reading that is never the limit")
        XCTAssertEqual(s.totalText, "< 128 GB/s")
        s.belowGBs = nil
        s.measuredTotalGBs = 738.4
        XCTAssertEqual(s.totalText, "738 GB/s")
    }

    /// A recording made before `belowGBs` existed still opens.
    func testBelowGBsDecodesAbsentAsNil() throws {
        let old = #"{"cpuGBs":0,"gpuGBs":0,"mediaGBs":0,"otherGBs":0,"isEstimated":true}"#
        let s = try JSONDecoder().decode(BandwidthSample.self, from: Data(old.utf8))
        XCTAssertNil(s.belowGBs)
    }
}
