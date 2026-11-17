//
//  File:      UltraDiePrefixedPowerTests.swift
//  Created:   2026-10-17
//  Updated:   2026-11-16
//  Developer: Spencer Curtis
//  Overview:  Pins the power split on a multi-die chip whose Energy Model CPU rails carry an
//             underscore die prefix and have no bare spelling: both dies' totals must land in the
//             CPU / E / P rows, and none of the per-core, SRAM or fabric siblings may.
//  Notes:     Every rail name here was read from a Mac Studio (M3 Ultra, macOS 27.0.1). Before
//             IOReportNaming learned `DIE_<digits>_`, all of the CPU rails below were skipped and
//             the CPU, E and P rows read 0.0 W. Energies are mJ over 60 s, so 60_000 is 1 W.
//
import XCTest
@testable import SiliconScopeCore

final class UltraDiePrefixedPowerTests: XCTestCase {

    private func rail(_ name: String, _ millijoules: Int) -> PowerSampler.Rail {
        PowerSampler.Rail(group: "Energy Model", subgroup: "", name: name, energy: millijoules)
    }

    func testBothDiesFeedTheCPURows() {
        let rails = [
            rail("DIE_0_CPU Energy", 120_000), rail("DIE_1_CPU Energy", 60_000),
            rail("DIE_0_EACC_CPU", 30_000), rail("DIE_1_EACC_CPU", 30_000),
            rail("DIE_0_PACC0_CPU", 30_000), rail("DIE_0_PACC1_CPU", 30_000),
            rail("DIE_1_PACC0_CPU", 30_000), rail("DIE_1_PACC1_CPU", 30_000),
            rail("ANE0_0", 60_000),
        ]
        let p = PowerSampler.classify(rails, seconds: 60)
        XCTAssertEqual(p.cpuWatts, 3, accuracy: 1e-9, "DIE_0 + DIE_1 CPU Energy")
        XCTAssertEqual(p.eCPUWatts, 1, accuracy: 1e-9, "both dies' EACC_CPU")
        XCTAssertEqual(p.pCPUWatts, 2, accuracy: 1e-9, "both dies' PACC0_CPU + PACC1_CPU")
        XCTAssertEqual(p.aneWatts, 1, accuracy: 1e-9)
    }

    /// The siblings of each cluster total are huge here so any one leaking in is unmissable.
    func testPerCoreSRAMAndFabricRailsAreNotSummed() {
        let siblings = [
            "DIE_0_EACC_CPU0", "DIE_0_EACC_CPU0_SRAM", "DIE_0_EACC_CPM", "DIE_0_EACC_CPM_SRAM",
            "DIE_1_PACC1_CPU5", "DIE_1_PACC1_CPU5_SRAM", "DIE_0_PACC0_CPM", "DIE_1_PACC0_CPM_SRAM",
            "DIE_0_ECPM v1", "DIE_0_ECPM v1 idle", "DIE_1_PCPM v19", "DIE_1_PCPM v19 idle",
            "PCPUDTL00", "PCPU1DTL0a", "ECPUDTL35",
        ].map { rail($0, 6_000_000) }
        let p = PowerSampler.classify(siblings + [rail("ANE0_0", 0)], seconds: 60)
        XCTAssertEqual(p.cpuWatts, 0, accuracy: 1e-9)
        XCTAssertEqual(p.eCPUWatts, 0, accuracy: 1e-9)
        XCTAssertEqual(p.pCPUWatts, 0, accuracy: 1e-9)
        XCTAssertEqual(p.gpuWatts, 0, accuracy: 1e-9)
        XCTAssertEqual(p.aneWatts, 0, accuracy: 1e-9)
        XCTAssertEqual(p.dramWatts, 0, accuracy: 1e-9)
    }
}
