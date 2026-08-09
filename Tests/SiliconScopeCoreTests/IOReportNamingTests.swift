//
//  File:      IOReportNamingTests.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the channel-name tolerance that #35 needs and #14/#30 already proved: a rail
//             keeps resolving when Apple prefixes it with a die/chip-id token, and does NOT start
//             resolving for a merely similar name.
//  Notes:     The prefixed spellings here are the ones actually observed by reporters — "DIE0
//             ECPU0" on a macOS 27 beta (#14) and "PRIM MCPU0 DCS" on M5 Max (#30). Everything
//             else is a negative case, because the whole risk of loosening a match is that it
//             starts matching something else; the leading-space anchor is what prevents that.
//
import XCTest
@testable import SiliconScopeCore

final class IOReportNamingTests: XCTestCase {

    // MARK: - isUnit — whole-unit names

    func testIsUnitAcceptsBareAndPrefixed() {
        XCTAssertTrue(IOReportNaming.isUnit("CPU Energy", "CPU Energy"))
        XCTAssertTrue(IOReportNaming.isUnit("DIE0 CPU Energy", "CPU Energy"))
        XCTAssertTrue(IOReportNaming.isUnit("PRIM ECPU", "ECPU"))
        XCTAssertTrue(IOReportNaming.isUnit("Energy Model", "Energy Model"))
        XCTAssertTrue(IOReportNaming.isUnit("DIE0 Energy Model", "Energy Model"))
    }

    /// The exclusion that keeps `GPU Energy` (nJ, a different unit) out of the watt sum must
    /// survive prefixing — otherwise a prefixed machine silently adds a rail in the wrong unit.
    func testIsUnitSeparatesGPUEnergyFromCPUEnergy() {
        XCTAssertTrue(IOReportNaming.isUnit("DIE0 GPU Energy", "GPU Energy"))
        XCTAssertFalse(IOReportNaming.isUnit("DIE0 GPU Energy", "CPU Energy"))
        XCTAssertFalse(IOReportNaming.isUnit("GPU Energy", "CPU Energy"))
    }

    /// A longer name that merely ENDS with the unit's letters is not the unit.
    func testIsUnitRejectsUnanchoredSuffix() {
        XCTAssertFalse(IOReportNaming.isUnit("XECPU", "ECPU"), "no separator — different unit")
        XCTAssertFalse(IOReportNaming.isUnit("ECPU0", "ECPU"), "per-core rail is not the cluster total")
        XCTAssertFalse(IOReportNaming.isUnit("ECPU", "PCPU"))
    }

    // MARK: - hasUnitPrefix — unit families with numeric suffixes

    func testHasUnitPrefixAcceptsBareAndPrefixed() {
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("GPU0", "GPU"))
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("DIE0 GPU0", "GPU"))
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("ANE1", "ANE"))
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("DIE0 ANE1", "ANE"))
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("EACC_CPU", "EACC"))
        XCTAssertTrue(IOReportNaming.hasUnitPrefix("DIE0 EACC_CPU", "EACC"))
    }

    /// Loosening must not make an unrelated unit match: the prefix has to sit at the start or
    /// right after a separator, never mid-token.
    func testHasUnitPrefixIsAnchored() {
        XCTAssertFalse(IOReportNaming.hasUnitPrefix("AGPU0", "GPU"), "mid-token match would be wrong")
        XCTAssertFalse(IOReportNaming.hasUnitPrefix("XANE", "ANE"))
        XCTAssertFalse(IOReportNaming.hasUnitPrefix("SDRAM", "DRAM"))
        XCTAssertFalse(IOReportNaming.hasUnitPrefix("PACC_CPU", "EACC"))
    }

    // MARK: - unitToken

    func testUnitTokenDropsLeadingChipID() {
        XCTAssertEqual(IOReportNaming.unitToken("MCPU0"), "MCPU0")
        XCTAssertEqual(IOReportNaming.unitToken("PRIM MCPU0"), "MCPU0")
        XCTAssertEqual(IOReportNaming.unitToken("DIE0 PCPU"), "PCPU")
        XCTAssertEqual(IOReportNaming.unitToken(""), "")
    }

    /// Documents the trap the doc comment warns about, so nobody "fixes" a multi-word unit with it.
    func testUnitTokenIsWrongForMultiWordUnits() {
        XCTAssertEqual(IOReportNaming.unitToken("CPU Energy"), "Energy",
                       "multi-word units must use isUnit, not unitToken")
    }

    // MARK: - The two samplers share one rule

    /// BandwidthSampler's `classify` was the original home of this tolerance (#14). It must still
    /// behave identically now that it delegates, or the power fix would have moved the bandwidth
    /// behaviour underneath a shipped feature.
    func testBandwidthClassifyStillToleratesChipIDToken() {
        XCTAssertEqual(BandwidthSampler.classify(requestor: "ECPU DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 ECPU0 DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "PRIM MCPU0 DCS"), .cpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DIE0 GFX DCS"), .gpu)
        XCTAssertEqual(BandwidthSampler.classify(requestor: "DCS"), .total)
    }
}
