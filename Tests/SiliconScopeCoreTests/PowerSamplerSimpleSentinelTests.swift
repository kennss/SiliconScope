//
//  File:      PowerSamplerSimpleSentinelTests.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Yurii Chukhlib
//  Overview:  Unit tests for `PowerSampler.simpleWatts` — the per-rail energy → watts conversion
//             that strips the IOReport "Simple" `INT64_MIN` "unpopulated" sentinel before the mJ → W
//             math. The same sentinel `BandwidthSimpleSentinelTests` pins for bandwidth, pinned here
//             for power so one dead rail can no longer swamp a whole domain's wattage.
//  Notes:     No hardware: `simpleWatts` is a pure (Int + TimeInterval → Double) seam extracted from
//             `sample()` for exactly this. The sentinel is `Int64.min` (`Int.min` on the 64-bit
//             target) — the value `channelDump()` labels "not populated, raw INT64_MIN". Pre-fix it
//             was read straight into `Double(...)` ≈ -9.2e18 mJ and dominated the per-domain sum; the
//             shared `IOReportNaming.sanitizeSimpleValue` now strips it before the division.
//
import XCTest
@testable import SiliconScopeCore

final class PowerSamplerSimpleSentinelTests: XCTestCase {

    // MARK: - INT64_MIN "unpopulated" sentinel → 0 W

    /// An unpopulated energy rail (the `Int.min` sentinel) must read as 0 W, not as a real energy
    /// delta. Before the guard it was divided straight into a huge-negative wattage that dominated
    /// whichever domain (CPU/GPU/ANE/DRAM) the dead rail happened to land in.
    func testSentinelRailReadsZeroWatts() {
        XCTAssertEqual(PowerSampler.simpleWatts(raw: .min, seconds: 0.2), 0,
                       "INT64_MIN / Int.min 'unpopulated' rail reads as 0 W, not a real energy delta")
    }

    // MARK: - Real readings convert correctly (mJ / s / 1000 = W)

    func testRealRailConvertsMillijoulesToWatts() {
        // 8000 mJ over 0.2 s = 40 W (a realistic GPU rail under load).
        XCTAssertEqual(PowerSampler.simpleWatts(raw: 8_000, seconds: 0.2), 40, accuracy: 1e-9)
        // 1200 mJ over 0.3 s = 4 W.
        XCTAssertEqual(PowerSampler.simpleWatts(raw: 1_200, seconds: 0.3), 4, accuracy: 1e-9)
    }

    /// Only `Int.min` is the documented sentinel. A real, non-sentinel negative value is NOT a
    /// sentinel and must convert unchanged — the guard must not silently zero legitimate data (a
    /// genuinely negative delta would itself be suspect, but that is a question for the caller, not
    /// a value the sentinel guard should hide).
    func testNonSentinelNegativeConvertsUnchanged() {
        XCTAssertEqual(PowerSampler.simpleWatts(raw: -1, seconds: 0.2),
                       Double(-1) / 0.2 / 1000.0, accuracy: 1e-9)
        XCTAssertEqual(PowerSampler.simpleWatts(raw: Int.min + 1, seconds: 0.2),
                       Double(Int.min + 1) / 0.2 / 1000.0, accuracy: 1e3)
    }

    // MARK: - The sentinel no longer corrupts a per-domain sum

    /// Two live rails plus one unpopulated rail (the sentinel). Pre-fix, the unguarded
    /// `Double(Int.min)` ≈ -9.2e18 dominated the sum; post-fix the dead rail contributes 0 W, so the
    /// domain total is just the two live rails. This is the `sample()` per-domain accumulation shape
    /// (e.g. GPU0 + GPU SRAM0 + an unpopulated sibling) in miniature.
    func testSentinelRailDoesNotCorruptDomainSum() {
        let rails = [8_000, 4_000, Int.min]   // two live rails + one unpopulated, over 0.2 s
        let watts = rails.reduce(0.0) { $0 + PowerSampler.simpleWatts(raw: $1, seconds: 0.2) }
        // 8000 mJ + 4000 mJ over 0.2 s = 60 W; the unpopulated rail adds nothing.
        XCTAssertEqual(watts, 60, accuracy: 1e-6,
                       "the unpopulated rail must contribute 0 W, leaving only the two live rails")
    }

    /// Documents the exact corruption the guard prevents: the same rails summed *without* the guard.
    /// It is a huge-negative, overflow-scale wattage — what a user would have seen before this fix.
    /// Kept as a regression witness so the failure mode is self-explanatory if the guard is removed.
    func testDocumentsThePreFixCorruption() {
        let rails = [8_000, 4_000, Int.min]
        let unguarded = rails.reduce(0.0) { $0 + Double($1) / 0.2 / 1000.0 }
        XCTAssertLessThan(unguarded, -1e16,
                          "pre-fix: Double(Int.min) dominates the sum — an overflow-scale wattage, the bug this guard fixes")
    }
}
