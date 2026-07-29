//
//  File:      CPUTopologyLevelTests.swift
//  Created:   2026-07-29
//  Updated:   2026-07-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the perf-level model that #30 exposed: a chip whose levels are named "Super" and
//             "Performance" (Apple M5 Max — no Efficiency level at all) must not be described with
//             E/P letters that mean something else, and its usage split must not be guessed.
//  Notes:     The M5 numbers are @ben0112's measurements on real hardware (6 Super + 12 Performance,
//             three 6-core clusters), which is why the cluster-size ambiguity below is a real case
//             and not a hypothetical: 6/6/6 has several groupings that sum to 12.
//
import XCTest
@testable import SiliconScopeCore

final class CPUTopologyLevelTests: XCTestCase {

    private func topology(chip: String, e: Int, p: Int,
                          pName: String?, eName: String?) -> CPUTopology {
        CPUTopology(chipName: chip, eCoreCount: e, pCoreCount: p,
                    eFreqsMHz: [], pFreqsMHz: [], gpuFreqsMHz: [],
                    pLevelName: pName, eLevelName: eName)
    }

    /// The familiar pair keeps the compact form users already recognise.
    func testClassicLevelsStillReadAsEAndP() {
        let m1 = topology(chip: "Apple M1 Max", e: 2, p: 8,
                          pName: "Performance", eName: "Efficiency")
        XCTAssertEqual(m1.coreSummary, "2E+8P")
        XCTAssertEqual(m1.pLabel, "Performance")
        XCTAssertEqual(m1.eLabel, "Efficiency")
    }

    /// M5 Max: calling six **Super** cores "E" is the bug — the letters have to give way.
    func testSuperLevelIsNamedNotLettered() {
        let m5 = topology(chip: "Apple M5 Max", e: 12, p: 6,
                          pName: "Super", eName: "Performance")
        XCTAssertEqual(m5.coreSummary, "6 Super + 12 Performance")
        XCTAssertFalse(m5.coreSummary.contains("E+"), "no chip without an Efficiency level may report E cores")
    }

    /// A remote Mac sends counts but no names — an older agent has none to send. The labels fall
    /// back to E/P rather than inventing one.
    func testUnnamedLevelsFallBackToLetters() {
        let remote = topology(chip: "Apple M2 Pro", e: 4, p: 8, pName: nil, eName: nil)
        XCTAssertEqual(remote.coreSummary, "4E+8P")
        XCTAssertEqual(remote.pLabel, "P-cores")
        XCTAssertEqual(remote.eLabel, "E-cores")
    }

    /// The usage split must never hand back a range that runs past the core count.
    func testSecondLevelRangeStaysInBounds() {
        for (cores, level1) in [(10, 2), (18, 12), (8, 0), (4, 9)] {
            let range = CPUTopology.secondLevelIndices(coreCount: cores, level1Count: level1)
            XCTAssertTrue(range.lowerBound >= 0 && range.upperBound <= cores,
                          "range \(range) escapes 0..<\(cores)")
        }
    }

    /// On this machine the device tree is readable, so the split is measured rather than assumed —
    /// and it must agree with what sysctl says the second level's size is.
    func testDeviceTreeSplitMatchesPerfLevelCountsOnThisMac() throws {
        let map = CPUClusterMap.read()
        try XCTSkipIf(map.isEmpty, "device tree exposes no cluster map on this machine")

        let levels = CPUTopology.perfLevels()
        try XCTSkipUnless(levels.count == 2, "test covers the two-level chips")
        let cores = levels.reduce(0) { $0 + $1.logicalCPUs }
        let range = CPUTopology.secondLevelIndices(coreCount: cores, level1Count: levels[1].logicalCPUs)

        XCTAssertEqual(range.count, levels[1].logicalCPUs,
                       "the second level's range must hold exactly its cores")
        XCTAssertEqual(map.count, cores, "device tree should list every logical CPU")
    }

    /// Every CPU in the map belongs to exactly one cluster, and clusters are contiguous — the
    /// samplers slice ranges, so a scattered cluster would silently average the wrong cores.
    func testClustersAreContiguousOnThisMac() throws {
        let map = CPUClusterMap.read()
        try XCTSkipIf(map.isEmpty, "device tree exposes no cluster map on this machine")

        for (cluster, members) in Dictionary(grouping: map, by: \.clusterID) {
            let indices = members.map(\.cpuIndex).sorted()
            guard let lo = indices.first, let hi = indices.last else { continue }
            XCTAssertEqual(hi - lo + 1, indices.count, "cluster \(cluster) is not contiguous: \(indices)")
        }
    }

    /// The KHz/Hz heuristic must survive M5's 4608 MHz ceiling — a table read in the wrong unit
    /// either reports single-digit "MHz" or a number no silicon reaches.
    func testVoltageStateUnitHeuristic() {
        // Hz-encoded (M1 style): 600 MHz and 2064 MHz, each followed by a voltage word.
        var hz = Data()
        for f in [600_000_000, 0, 2_064_000_000, 0] as [UInt32] { withUnsafeBytes(of: f.littleEndian) { hz.append(contentsOf: $0) } }
        XCTAssertEqual(CPUClusterMap.decodeVoltageStates(hz), [600, 2064])

        // KHz-encoded (M4/M5 style): 1308 MHz and 4608 MHz.
        var khz = Data()
        for f in [1_308_000, 0, 4_608_000, 0] as [UInt32] { withUnsafeBytes(of: f.littleEndian) { khz.append(contentsOf: $0) } }
        XCTAssertEqual(CPUClusterMap.decodeVoltageStates(khz), [1308, 4608])
    }
}
