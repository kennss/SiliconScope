//
//  File:      BandwidthSimpleSentinelTests.swift
//  Created:   2026-08-09
//  Updated:   2026-08-10
//  Developer: Yurii Chukhlib
//  Overview:  Unit tests for `IOReportNaming.sanitizeSimpleValue` — the guard that stops an
//             IOReport "Simple" bandwidth channel's documented `INT64_MIN` "unpopulated" sentinel
//             from being summed/averaged as a real byte delta.
//  Notes:     No hardware: these exercise a pure Int → Int helper, the boundary that's impossible
//             to hit deterministically through `sample()` (which needs a live IOReport subscription
//             and an unpopulated channel). The sentinel is the same value `channelDump()` already
//             labels "not populated, raw INT64_MIN"; this test pins the behavior at the read/
//             accumulate site so a single unpopulated lane can no longer corrupt the whole bus's
//             GB/s (the pre-fix failure: `Double(Int.min)` ≈ -9.2e18 bytes dominates the sum).
//
import XCTest
@testable import SiliconScopeCore

final class BandwidthSimpleSentinelTests: XCTestCase {

    // MARK: - INT64_MIN "unpopulated" sentinel → 0

    /// The documented IOReport "unpopulated" sentinel (`Int64.min`, which is `Int.min` on the
    /// 64-bit target) must read as "no data" (0), not as a real byte delta. Before this guard
    /// existed it was summed straight into the per-bus total, producing a huge-negative GB/s.
    func testSentinelMapsToZero() {
        // `.min` resolves to `Int.min` (== Int64.min == INT64_MIN on the 64-bit target).
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(.min), 0,
                       "INT64_MIN / Int.min 'unpopulated' sentinel reads as 0, not a real byte delta")
    }

    // MARK: - Real readings pass through unchanged

    func testNormalReadingPassesThrough() {
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(0), 0)
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(1_500_000_000), 1_500_000_000)
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(2_000_000_000_000), 2_000_000_000_000)
    }

    /// Only `Int.min` is the documented sentinel. A real, non-sentinel negative value is NOT a
    /// sentinel and must survive unchanged — the guard must not silently zero legitimate data.
    func testNonSentinelNegativePassesThrough() {
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(-1), -1)
        // Int.min + 1 is the largest-in-magnitude negative that is NOT the sentinel.
        XCTAssertEqual(IOReportNaming.sanitizeSimpleValue(Int.min + 1), Int.min + 1)
    }

    // MARK: - The sentinel no longer corrupts a per-bus sum

    /// Two live DRAM-BW lanes plus one unpopulated lane (the sentinel). Pre-fix, the unguarded
    /// `Double(Int.min)` ≈ -9.2e18 dominated the sum; post-fix the dead lane contributes 0, so the
    /// bus total is just the two live lanes. This is the A18 `sampleA18Simple` total-accumulation
    /// shape and the M-series `sampleAMCStatsSimple` per-requestor accumulation shape, in miniature.
    func testSentinelLaneDoesNotCorruptSum() {
        let lanes = [2_000_000_000, 3_000_000_000, Int.min]   // two live lanes + one unpopulated
        let totalBytes = lanes.reduce(0.0) { $0 + Double(IOReportNaming.sanitizeSimpleValue($1)) }
        XCTAssertEqual(totalBytes, 5_000_000_000, accuracy: 1e-6,
                       "the unpopulated lane must contribute 0, leaving only the two live lanes")
    }

    /// Documents the exact corruption the guard prevents: the same lanes summed *without* the guard.
    /// It is wildly negative — what a user would have seen before this fix. Kept as a regression
    /// witness so the failure mode is self-explanatory if the guard is ever removed.
    func testDocumentsThePreFixCorruption() {
        let lanes = [2_000_000_000, 3_000_000_000, Int.min]
        let unguarded = lanes.reduce(0.0) { $0 + Double($1) }
        XCTAssertLessThan(unguarded, -1e18,
                          "pre-fix: Double(Int.min) ≈ -9.2e18 dominates the sum — an overflow-scale value, the bug this guard fixes")
    }
}
