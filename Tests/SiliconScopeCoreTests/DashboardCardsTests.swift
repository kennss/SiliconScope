//
//  File:      DashboardCardsTests.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the dashboard's hidden-card set: how it is stored, and what the dashboard
//             asks the monitor to measure once cards are hidden.
//  Notes:     The demand cases are the point. A card left out of demand would show a value
//             carried forward from the last tick that measured it, so these pin both directions:
//             hiding a card drops what only it reads, and never drops what a shown card reads.
//
import XCTest
@testable import SiliconScopeCore

final class DashboardCardsTests: XCTestCase {

    // MARK: - Storage

    func testEmptyStorageShowsEveryCard() {
        let v = DashboardCardVisibility(storage: "")
        XCTAssertTrue(DashboardCard.allCases.allSatisfy(v.isShown))
        XCTAssertFalse(v.allHidden)
    }

    func testStorageRoundTripsInCardOrder() {
        var v = DashboardCardVisibility()
        v.set(.processes, shown: false)
        v.set(.aiWorkload, shown: false)
        XCTAssertEqual(v.storage, "aiWorkload,processes")
        XCTAssertEqual(DashboardCardVisibility(storage: v.storage), v)
    }

    /// A name this build doesn't know (a card renamed or removed later) is skipped, and the rest of
    /// the list survives it.
    func testUnknownNamesAreSkippedNotFatal() {
        let v = DashboardCardVisibility(storage: "gpuTimeline, sensors,,cpu")
        XCTAssertEqual(v.hidden, [.sensors, .cpu])
    }

    func testShowingAgainRemovesFromTheSet() {
        var v = DashboardCardVisibility(storage: "cpu,sensors")
        v.set(.cpu, shown: true)
        XCTAssertEqual(v.storage, "sensors")
    }

    func testAllHidden() {
        let v = DashboardCardVisibility(hidden: Set(DashboardCard.allCases))
        XCTAssertTrue(v.allHidden)
    }

    func testSetShownWritesOnlyThatCard() throws {
        let suite = "DashboardCardsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("networkDisk", forKey: DashboardCardVisibility.key)
        DashboardCardVisibility.setShown(.aiRuntime, false, in: defaults)
        XCTAssertEqual(defaults.string(forKey: DashboardCardVisibility.key), "aiRuntime,networkDisk")
        DashboardCardVisibility.setShown(.networkDisk, true, in: defaults)
        XCTAssertEqual(defaults.string(forKey: DashboardCardVisibility.key), "aiRuntime")
    }

    func testTitlesAreDistinct() {
        XCTAssertEqual(Set(DashboardCard.allCases.map(\.title)).count, DashboardCard.allCases.count)
    }

    // MARK: - Demand

    /// Every card shown reads every group except peripherals, which the dashboard never displays
    /// (they live in the menu bar's battery dropdown, whose own demand covers them).
    func testEveryCardShownDemandsAllButPeripherals() {
        let d = DashboardCardVisibility().demand(warningBanner: true)
        XCTAssertEqual(d, MetricGroup.all.subtracting(.peripherals))
    }

    /// The process table is the costliest walk, and three cards read it. Hiding all three is
    /// what stops it.
    func testHidingEveryProcessReaderDropsTheProcessTable() {
        let v = DashboardCardVisibility(hidden: [.processes, .aiWorkload, .aiRuntime])
        XCTAssertFalse(v.demand(warningBanner: true).contains(.processes))
        // One of them alone is not enough.
        XCTAssertTrue(DashboardCardVisibility(hidden: [.processes]).demand(warningBanner: true).contains(.processes))
    }

    func testNetworkAndDiskStopWithTheirCard() {
        let d = DashboardCardVisibility(hidden: [.networkDisk]).demand(warningBanner: true)
        XCTAssertFalse(d.contains(.network))
        XCTAssertFalse(d.contains(.disk))
    }

    /// ⚠️ Hiding Sensors must not stop temperatures while a shown card's throttle verdict reads
    /// them: the CPU card's P-ceiling line appears on die heat.
    func testAShownVerdictKeepsItsTemperature() {
        let d = DashboardCardVisibility(hidden: [.sensors, .accelerators, .aiWorkload])
            .demand(warningBanner: false)
        XCTAssertTrue(d.contains(.temperature))
        XCTAssertTrue(d.contains(.thermal))
    }

    /// The banner's verdicts are the alert path's, so it keeps them measured on its own.
    func testTheBannerKeepsTheAlertGroups() {
        let onlyMemory = DashboardCardVisibility(hidden: Set(DashboardCard.allCases).subtracting([.memoryBandwidth]))
        XCTAssertEqual(onlyMemory.demand(warningBanner: false),
                       DashboardCardVisibility.headerDemand.union([.memory, .bandwidth]))
        XCTAssertTrue(onlyMemory.demand(warningBanner: true).isSuperset(of: .alerts))
    }

    func testAllHiddenLeavesTheHeader() {
        let v = DashboardCardVisibility(hidden: Set(DashboardCard.allCases))
        XCTAssertEqual(v.demand(warningBanner: false), DashboardCardVisibility.headerDemand)
    }
}
