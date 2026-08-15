//
//  File:      BandwidthPMPHistogramTests.swift
//  Created:   2026-07-15
//  Updated:   2026-08-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Unit tests for the PMP "DCS BW" histogram fallback path in BandwidthSampler —
//             the residency-weighted-average math, the "NGB/s" state-name parser, requestor
//             classification, and aggregate-only AMCC fallback.
//  Notes:     No hardware: these are pure functions over explicit inputs. Fixtures come from
//             M4/M5 Max macOS 26.5.2 per-requestor histograms and the M3 Max macOS 27
//             aggregate-only histogram documented in docs/ioreport-channels.md.
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
        // ANE, fabric/coherency, and display requestors have no dedicated bucket in
        // BandwidthSample and fold into other, matching the classic path's MSR/DISP/ANS handling.
        for other in ["ANE0", "ANS", "ATC0", "ATC3", "DISPEXT0", "DISPINT", "MSR0", "MSR1", "AMCC"] {
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
        // M5 ANE is "ANE L0"/"ANE L1" (was "ANE0") — still folds into other (no ANE bandwidth bucket).
        for other in ["ANE L0", "ANE L1", "MSR0", "MSR1", "DISPINT", "DISPEXT0"] {
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

    func testPMPHistogramUsesSoleAMCCAsMeasuredTotal() {
        // Live M3 Max/macOS 27 fixture: PMP0/DCS BW exposes only AMCC while GPU is loaded.
        let total = BandwidthSampler.pmpMeasuredTotalGBs(
            aggregateGBs: 278.695,
            aggregateChannelCount: 1,
            perRequestorChannelCount: 0
        )
        XCTAssertEqual(total ?? -1, 278.695, accuracy: 0.001)
    }

    func testPMPHistogramIgnoresAMCCBesidePerRequestorChannels() {
        // M5's AMCC has an idle floor and must not be added to its real requestor lanes.
        XCTAssertNil(BandwidthSampler.pmpMeasuredTotalGBs(
            aggregateGBs: 40.1,
            aggregateChannelCount: 1,
            perRequestorChannelCount: 20
        ))
    }

    func testPMPHistogramRejectsMissingOrAmbiguousAggregate() {
        XCTAssertNil(BandwidthSampler.pmpMeasuredTotalGBs(
            aggregateGBs: nil,
            aggregateChannelCount: 0,
            perRequestorChannelCount: 0
        ))
        XCTAssertNil(BandwidthSampler.pmpMeasuredTotalGBs(
            aggregateGBs: 200,
            aggregateChannelCount: 2,
            perRequestorChannelCount: 0
        ))
    }
}
