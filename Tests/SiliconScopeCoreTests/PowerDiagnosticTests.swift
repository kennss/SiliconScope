//
//  File:      PowerDiagnosticTests.swift
//  Created:   2026-08-10
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins what `--power-debug` tells a reporter, for the machine shapes we cannot run.
//             #35 is a macOS 27 beta on an M1 Max where every wattage reads 0.0 while temperature,
//             bandwidth and GPU usage keep working — the fingerprint of the power GROUP being
//             missing or renamed rather than individual rails changing.
//  Notes:     `channelSummary` is pure over its rows, so all three machine shapes below are
//             synthetic. That is the point: the one thing we cannot do is boot the reporter's OS,
//             so the diagnostic's answer for that OS has to be locked in from here.
//
import XCTest
@testable import SiliconScopeCore

final class PowerDiagnosticTests: XCTestCase {

    private func row(_ group: String, _ name: String, raw: Int, sub: String = "") -> PowerSampler.ChannelRow {
        PowerSampler.ChannelRow(group: group, subgroup: sub, name: name,
                                raw: raw, watts: Double(raw) / 0.3 / 1000.0)
    }

    /// M1 Max on a shipping macOS — the shape every current user has.
    private func healthy() -> [PowerSampler.ChannelRow] {
        [row("Energy Model", "CPU Energy", raw: 728),
         row("Energy Model", "GPU0", raw: 89),
         row("Energy Model", "ANE0", raw: 0),
         row("Energy Model", "DRAM0", raw: 855),
         row("PMP", "ECPU", raw: 40, sub: "Energy Counters"),
         row("SoC Stats", "IRQ", raw: 12)]
    }

    func testHealthyMachineReportsBothGroupsPresent() {
        let s = PowerSampler.channelSummary(healthy()).joined(separator: "\n")
        XCTAssertTrue(s.contains("Energy Model: present as \"Energy Model\""))
        XCTAssertTrue(s.contains("PMP: present as \"PMP\""))
        XCTAssertFalse(s.contains("ABSENT"))
    }

    /// An ANE reading 0 W is normal at idle, so the summary must still SHOW the channel — its
    /// absence and its zero mean very different things, and only one of them is a bug.
    func testIdleANEChannelIsListedEvenAtZero() {
        let s = PowerSampler.channelSummary(healthy()).joined(separator: "\n")
        XCTAssertTrue(s.contains("ANE0"), "a zero ANE rail is evidence, not noise")
    }

    /// #35's leading hypothesis: the group is prefixed with a die token, so a bare-name lookup
    /// finds nothing and every rail reads 0.0 W. The summary has to resolve it AND say so.
    func testDiePrefixedGroupIsRecognised() {
        let rows = [row("DIE0 Energy Model", "DIE0 GPU0", raw: 89),
                    row("DIE0 Energy Model", "DIE0 ANE0", raw: 0)]
        let s = PowerSampler.channelSummary(rows).joined(separator: "\n")
        XCTAssertTrue(s.contains("present as \"DIE0 Energy Model\""),
                      "a prefixed group must be reported as found, under its real name")
        XCTAssertTrue(s.contains("DIE0 GPU0"), "its rails must be listed so a rename is visible too")
    }

    /// The other #35 shape: the power group is gone under any name we know. The reporter must be
    /// told that explicitly — this single line is what turns "0.0 W" from a mystery into a fact.
    func testAbsentPowerGroupIsCalledOut() {
        let rows = [row("SoC Stats", "IRQ", raw: 12),
                    row("AMC Stats", "DCS RD", raw: 400)]
        let s = PowerSampler.channelSummary(rows).joined(separator: "\n")
        XCTAssertTrue(s.contains("Energy Model: ABSENT"))
        XCTAssertTrue(s.contains("every wattage will read 0.0 W"))
    }

    /// A group renamed to something we have never seen must still surface, or the reporter and the
    /// maintainer both go looking in the wrong place.
    func testUnknownPowerLikeGroupStillSurfaces() {
        let rows = [row("SoC Energy Metrics", "GPU0", raw: 89),
                    row("SoC Stats", "IRQ", raw: 12)]
        let s = PowerSampler.channelSummary(rows).joined(separator: "\n")
        XCTAssertTrue(s.contains("Energy Model: ABSENT"))
        XCTAssertTrue(s.contains("SoC Energy Metrics"),
                      "a power-like group name must be listed even when we do not read it")
    }

    /// Empty input is the non-Apple-Silicon / IOReport-unavailable case; it must not look like an
    /// answer about groups.
    func testEmptyRowsSayNothingWasRead() {
        let s = PowerSampler.channelSummary([]).joined(separator: "\n")
        XCTAssertTrue(s.contains("no Simple channels"))
        XCTAssertFalse(s.contains("ABSENT"))
    }

    /// The summary exists to be pasted into an issue — if it can grow to thousands of lines it is
    /// the same unusable dump it replaced.
    func testSummaryStaysPasteable() {
        let many = (0..<500).map { row("Energy Model", "RAIL\($0)", raw: $0 + 1) }
        let lines = PowerSampler.channelSummary(many)
        XCTAssertLessThan(lines.count, 60, "summary must stay small enough to paste into an issue")
        XCTAssertTrue(lines.joined(separator: "\n").contains("more (add --full"))
    }
}
