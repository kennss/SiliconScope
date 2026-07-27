//
//  File:      MenuBarItemStoreTests.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the #27 phase-4a migration off the legacy per-metric `menubar.*` Bools, plus the
//             1:N pin semantics and the model's validation/repair rules. This is the only part of
//             Part B that can be tested — the app target has no test target — and it is also the
//             part that can silently empty a user's menu bar, which is why it exists.
//  Notes:     Every test runs against a scratch `UserDefaults` suite, never the real preferences.
//             The suite is removed in tearDown; `removePersistentDomain` alone is not enough because
//             a suite stays registered in the process, so each test also uses a unique suite name.
//
import XCTest
@testable import SiliconScopeCore

final class MenuBarItemStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ss.tests.menubar.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Migration

    /// A never-configured install (no keys at all) must migrate to exactly the combined "SS" item.
    /// `UserDefaults.bool` returns false for an absent key, so a naive migration would produce an
    /// EMPTY menu bar here — the app would appear to have uninstalled itself.
    func testFreshInstallMigratesToCombinedOnly() {
        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.metric), [.combined])
        XCTAssertEqual(defaults.integer(forKey: MenuBarItemStore.schemaVersionKey),
                       MenuBarItemStore.currentSchemaVersion)
    }

    /// The three keys that predate the metric names (`mem`/`net`/`ssd`) must map to the right
    /// metrics. Deriving keys from `MetricKind.rawValue` would drop all three.
    func testLegacyKeyNamesMapToRenamedMetrics() {
        defaults.set(true, forKey: "menubar.mem")
        defaults.set(true, forKey: "menubar.net")
        defaults.set(true, forKey: "menubar.ssd")
        defaults.set(false, forKey: "menubar.combined")

        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.metric), [.memory, .network, .disk])
    }

    /// Migration preserves the order of the retired static Spec array (combined first, then the
    /// per-metric items), so the migrated menu bar is created in the order the user already had.
    func testMigrationPreservesCanonicalOrder() {
        for key in ["menubar.battery", "menubar.cpu", "menubar.sensors"] { defaults.set(true, forKey: key) }

        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.metric), [.combined, .cpu, .sensors, .battery])
    }

    /// An explicitly disabled combined item must stay disabled — absence means ON, `false` does not.
    func testCombinedExplicitlyOffIsNotMigrated() {
        defaults.set(false, forKey: "menubar.combined")
        defaults.set(true, forKey: "menubar.gpu")

        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.metric), [.gpu])
    }

    /// Migrated items must reproduce today's hardcoded glyphs exactly, or an existing install's
    /// menu bar changes appearance on upgrade.
    func testMigratedItemsUseTodaysGlyphDefaults() throws {
        defaults.set(true, forKey: "menubar.cpu")
        defaults.set(true, forKey: "menubar.gpu")
        defaults.set(false, forKey: "menubar.combined")

        let store = MenuBarItemStore(defaults: defaults)
        let cpu = try XCTUnwrap(store.items.first { $0.metric == .cpu })
        XCTAssertEqual(cpu.mode, .bars)
        XCTAssertEqual(cpu.channels, [.cpuEfficiency, .cpuPerformance])

        let gpu = try XCTUnwrap(store.items.first { $0.metric == .gpu })
        XCTAssertEqual(gpu.mode, .bars)
        XCTAssertEqual(gpu.channels, [.gpuUtilisation, .mediaThroughput, .anePower])
    }

    /// Migration must run exactly once. A second store over the same defaults must not re-synthesise
    /// from the frozen Bools and clobber edits made after the upgrade.
    func testMigrationRunsOnceAndDoesNotClobberLaterEdits() {
        defaults.set(true, forKey: "menubar.cpu")
        let first = MenuBarItemStore(defaults: defaults)
        first.removeAll(of: .combined)
        first.append(.memory)
        let after = first.items.map(\.metric)

        let second = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(second.items.map(\.metric), after)
        XCTAssertEqual(second.items.map(\.metric), [.cpu, .memory])
    }

    /// The legacy keys are frozen: migration reads them and nothing ever writes them again, so a
    /// downgrade restores the layout as it was at upgrade time (documented in the release notes).
    func testLegacyKeysAreNeverWritten() {
        defaults.set(true, forKey: "menubar.cpu")
        let store = MenuBarItemStore(defaults: defaults)

        store.setPinned(true, for: .battery)
        store.setPinned(false, for: .cpu)

        XCTAssertNil(defaults.object(forKey: "menubar.battery"))
        XCTAssertEqual(defaults.bool(forKey: "menubar.cpu"), true, "the frozen snapshot must not change")
    }

    /// An empty menu bar is a legitimate state and must survive a reload — emptiness must not be
    /// mistaken for "not loaded yet" and re-trigger migration.
    func testEmptyListSurvivesReload() {
        let store = MenuBarItemStore(defaults: defaults)
        store.replaceAll(with: [])
        XCTAssertTrue(store.items.isEmpty)

        let reloaded = MenuBarItemStore(defaults: defaults)
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    // MARK: - Pin semantics (1:N)

    func testPinOnAppendsAndPinOffRemovesEveryInstance() {
        let store = MenuBarItemStore(defaults: defaults)
        store.append(.cpu)
        store.append(.cpu)
        XCTAssertEqual(store.items.filter { $0.metric == .cpu }.count, 2)
        XCTAssertTrue(store.isPinned(.cpu))

        store.setPinned(false, for: .cpu)
        XCTAssertFalse(store.isPinned(.cpu))
        XCTAssertTrue(store.items.filter { $0.metric == .cpu }.isEmpty)
    }

    /// Re-flipping a pin that is already on must not duplicate: the pin is derived state, and a
    /// card's toggle can fire again for reasons the user did not intend.
    func testPinOnIsIdempotent() {
        let store = MenuBarItemStore(defaults: defaults)
        store.setPinned(true, for: .memory)
        store.setPinned(true, for: .memory)
        XCTAssertEqual(store.items.filter { $0.metric == .memory }.count, 1)
    }

    /// A duplicate keeps the source's configuration but must take a new identity, or macOS would
    /// give both status items the same autosave slot.
    func testDuplicateCopiesConfigButNotIdentity() {
        let store = MenuBarItemStore(defaults: defaults)
        let source = store.append(.cpu)
        let copy = store.duplicate(source.id)

        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, source.id)
        XCTAssertNotEqual(copy?.autosaveName, source.autosaveName)
        XCTAssertEqual(copy?.mode, source.mode)
        XCTAssertEqual(copy?.channels, source.channels)
        // Inserted next to its source, not appended to the end.
        XCTAssertEqual(store.items.map(\.metric).suffix(2), [.cpu, .cpu])
    }

    // MARK: - Persistence and repair

    func testItemsRoundTripThroughDefaults() {
        let store = MenuBarItemStore(defaults: defaults)
        store.replaceAll(with: [MenuBarItemConfig(metric: .gpu, mode: .graph, channels: [.gpuUtilisation])])

        let reloaded = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items.first?.mode, .graph)
        XCTAssertEqual(reloaded.items.first?.channels, [.gpuUtilisation])
    }

    /// A stored item whose mode is no longer offered is repaired to the metric's defaults, never
    /// dropped: the user keeps the entry they placed.
    func testStoredItemWithRetiredModeIsRepairedNotDropped() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","metric":"network","mode":"bars","channels":["networkDown","networkUp"]}]
        """
        defaults.set(Data(json.utf8), forKey: MenuBarItemStore.itemsKey)
        defaults.set(MenuBarItemStore.currentSchemaVersion, forKey: MenuBarItemStore.schemaVersionKey)

        let store = MenuBarItemStore(defaults: defaults)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.metric, .network)
        XCTAssertEqual(item.mode, .twoLine, "bars is not offered for a rate metric")
        XCTAssertTrue(item.isValid)
    }

    /// The mode was called "histogram" while it drew bars. A config written then must still
    /// decode — a String-backed Codable enum throws on an unknown value, and one throwing element
    /// fails the WHOLE array, which for this type means an empty menu bar.
    func testPreReleaseHistogramRawValueStillDecodesAsGraph() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","metric":"cpu","mode":"histogram","channels":["cpuPerformance"]}]
        """
        defaults.set(Data(json.utf8), forKey: MenuBarItemStore.itemsKey)
        defaults.set(MenuBarItemStore.currentSchemaVersion, forKey: MenuBarItemStore.schemaVersionKey)

        let store = MenuBarItemStore(defaults: defaults)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.mode, .graph)
        XCTAssertTrue(item.isValid)
    }

    /// One undecodable item must cost one item, not the whole menu bar — the difference between a
    /// blemish and the app looking uninstalled.
    func testOneUndecodableItemDoesNotEmptyTheList() {
        let json = """
        [{"id":"\(UUID().uuidString)","metric":"cpu","mode":"bars","channels":["cpuEfficiency","cpuPerformance"]},
         {"id":"\(UUID().uuidString)","metric":"cpu","mode":"teleport","channels":["cpuPerformance"]},
         {"id":"\(UUID().uuidString)","metric":"battery","mode":"icon","channels":["batteryPercent"]}]
        """
        defaults.set(Data(json.utf8), forKey: MenuBarItemStore.itemsKey)
        defaults.set(MenuBarItemStore.currentSchemaVersion, forKey: MenuBarItemStore.schemaVersionKey)

        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.metric), [.cpu, .battery])
    }

    /// Corrupt JSON must not crash or wipe the schema version; it degrades to an empty list.
    func testCorruptStoredDataDegradesToEmpty() {
        defaults.set(Data("not json".utf8), forKey: MenuBarItemStore.itemsKey)
        defaults.set(MenuBarItemStore.currentSchemaVersion, forKey: MenuBarItemStore.schemaVersionKey)

        let store = MenuBarItemStore(defaults: defaults)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Model rules

    /// `bars` for a rate metric would be a fill bar with no ceiling to fill against — the model
    /// refuses it, which is the no-invented-numbers rule expressed in the type system. A histogram
    /// is different: it shows shape, not level, so it IS offered once the renderer can scale a
    /// ceiling-less series against the window's own maximum.
    func testRateMetricsRejectBarsButAllowGraph() {
        for metric in [MetricKind.network, .disk] {
            XCTAssertFalse(metric.supportedModes.contains(.bars), "\(metric) must not offer bars")
            XCTAssertTrue(metric.supportedModes.contains(.graph), "\(metric) should offer a graph")
        }
        XCTAssertTrue(MetricKind.sensors.supportedModes.contains(.graph))
        // Nothing records battery % over time, so it stays off.
        XCTAssertFalse(MetricKind.battery.supportedModes.contains(.graph))
    }

    /// A graph may only draw channels that have a series. Disk records read/write but not
    /// used/free, so offering the mode must not also offer a chart of nothing.
    func testGraphChannelsAreRestrictedToThoseWithHistory() {
        XCTAssertEqual(MetricKind.disk.channels(for: .graph), [.diskRead, .diskWrite])
        XCTAssertEqual(MetricKind.disk.channels(for: .twoLine), MetricKind.disk.channels)
        XCTAssertEqual(MetricKind.sensors.channels(for: .graph), [.sensorPrimaryTemp])
        XCTAssertEqual(MetricKind.memory.channels(for: .graph), [.memoryUsed, .memoryFree])
        for metric in MetricKind.allCases where metric.supportedModes.contains(.graph) {
            XCTAssertFalse(metric.channels(for: .graph).isEmpty,
                           "\(metric) offers a graph but has no graphable channel")
        }
    }

    /// Selecting a seriesless channel for a graph is invalid, and repairs rather than drawing
    /// an empty chart.
    func testGraphOfASeriesLessChannelIsInvalid() {
        let bad = MenuBarItemConfig(metric: .disk, mode: .graph, channels: [.diskUsed])
        XCTAssertFalse(bad.isValid)
        XCTAssertTrue(bad.repaired().isValid)
        let good = MenuBarItemConfig(metric: .disk, mode: .graph, channels: [.diskRead])
        XCTAssertTrue(good.isValid)
    }

    /// Every metric's own defaults must be valid, or a freshly added item would render as garbage.
    func testEveryMetricDefaultIsValid() {
        for metric in MetricKind.allCases {
            let item = MenuBarItemConfig(metric: metric)
            XCTAssertTrue(item.isValid, "\(metric) default is not well-formed")
            XCTAssertTrue(metric.defaultChannels.allSatisfy(metric.channels.contains),
                          "\(metric) default channels are not a subset of its channels")
        }
    }

    /// Arity is part of the model so the UI never has to remember it: twoLine draws exactly two
    /// rows, value exactly one.
    func testChannelCountMustFitModeArity() {
        let tooFew = MenuBarItemConfig(metric: .cpu, mode: .twoLine, channels: [.cpuEfficiency])
        XCTAssertFalse(tooFew.isValid)
        XCTAssertEqual(tooFew.repaired().mode, MetricKind.cpu.defaultMode)

        let tooMany = MenuBarItemConfig(metric: .memory, mode: .value,
                                        channels: [.memoryUsed, .memoryFree])
        XCTAssertFalse(tooMany.isValid)
    }

    /// A channel borrowed from another metric is not renderable by this item's dropdown.
    func testForeignChannelIsInvalid() {
        let item = MenuBarItemConfig(metric: .cpu, mode: .value, channels: [.batteryPercent])
        XCTAssertFalse(item.isValid)
        XCTAssertTrue(item.repaired().isValid)
    }

    /// Repair keeps identity — a repaired item must not lose its macOS status-item slot.
    func testRepairKeepsIdentity() {
        let item = MenuBarItemConfig(metric: .cpu, mode: .icon, channels: [.cpuEfficiency])
        XCTAssertEqual(item.repaired().id, item.id)
        XCTAssertEqual(item.repaired().autosaveName, item.autosaveName)
    }
}
