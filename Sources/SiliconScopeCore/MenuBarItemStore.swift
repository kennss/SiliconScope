//
//  File:      MenuBarItemStore.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Persistence for the menu-bar item list (#27, phase 4a) and the one-way migration off
//             the eight legacy per-metric `menubar.*` Bools. Lives in Core, next to the model, so
//             the migration is unit-testable — the app target has no test target, and the migration
//             is the part that can silently destroy a user's menu bar.
//  Notes:     ⚠️ NOT thread-safe and deliberately NOT `@MainActor` — Core must stay free of UI
//             isolation (CLAUDE.md §8.3). The app owns a single instance from the main actor.
//             ⚠️ `items` is CACHED. `sync()` runs at 1 Hz even with the dashboard closed, so the
//             JSON must never be decoded on that path (docs/energy-optimization.md FIX 3/4). The
//             cache is invalidated only by this type's own mutations.
//             Migration guards on `menubar.schemaVersion`, NOT on the presence of `menubar.items`:
//             presence alone would let a downgrade → toggle → re-upgrade silently discard the
//             interim change. After migrating, the legacy keys are frozen — read once here, never
//             written again — so downgrading restores the layout as it was at upgrade time.
//
import Foundation

/// Owns the ordered list of menu-bar item instances and its persistence.
///
/// Order is *creation* order, not screen order: macOS owns status-item position (users ⌘-drag them
/// and the system persists it per `autosaveName`), which is why the model carries no `order` field.
public final class MenuBarItemStore {

    // MARK: - Keys

    /// JSON array of `MenuBarItemConfig`.
    public static let itemsKey = "menubar.items"
    /// Schema version of `itemsKey`'s contents. Absent (0) means "never migrated".
    public static let schemaVersionKey = "menubar.schemaVersion"
    /// 1 — the instance list replaces the legacy per-metric Bools.
    public static let currentSchemaVersion = 1

    /// The eight frozen legacy keys. Read exactly once, by `migrate()`; never written.
    ///
    /// The mapping is not mechanical — three keys predate the metric names (`mem`/`net`/`ssd`), so
    /// deriving them from `MetricKind.rawValue` would silently migrate an empty menu bar.
    static let legacyKeys: [MetricKind: String] = [
        .combined: "menubar.combined",
        .cpu:      "menubar.cpu",
        .gpu:      "menubar.gpu",
        .memory:   "menubar.mem",
        .network:  "menubar.net",
        .disk:     "menubar.ssd",
        .sensors:  "menubar.sensors",
        .battery:  "menubar.battery",
    ]

    // MARK: - State

    private let defaults: UserDefaults
    /// Decoded items. `nil` means "not loaded yet"; an empty array is a legitimate loaded value
    /// (a user may hide every item), so emptiness must not be used as the sentinel.
    private var cache: [MenuBarItemConfig]?

    /// - Parameter defaults: injected so tests can run against a scratch suite instead of the
    ///   user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    // MARK: - Reading

    /// The current items. Cached — safe to call on the 1 Hz tick.
    public var items: [MenuBarItemConfig] {
        if let cache { return cache }
        let loaded = decode()
        cache = loaded
        return loaded
    }

    /// Whether a metric has at least one instance. This is what a card's pin reflects: under a 1:N
    /// model "pinned" is derived state, never stored.
    public func isPinned(_ metric: MetricKind) -> Bool {
        items.contains { $0.metric == metric }
    }

    // MARK: - Mutating

    /// Pin semantics under 1:N, per docs/design-system.md §4.4:
    /// - on  → append one instance in the metric's default mode, but only if it has none, so that
    ///         re-flipping a pin that is already on cannot silently duplicate an item;
    /// - off → remove *every* instance of that metric.
    public func setPinned(_ on: Bool, for metric: MetricKind) {
        if on {
            guard !isPinned(metric) else { return }
            append(metric)
        } else {
            removeAll(of: metric)
        }
    }

    /// Adds one instance of `metric` in its default mode and channels.
    @discardableResult
    public func append(_ metric: MetricKind) -> MenuBarItemConfig {
        let item = MenuBarItemConfig(metric: metric)
        write(items + [item])
        return item
    }

    /// Copies an existing instance, keeping its mode and channels but taking a NEW identity — the
    /// copy must get its own `autosaveName`, or macOS would give both items the same slot.
    @discardableResult
    public func duplicate(_ id: UUID) -> MenuBarItemConfig? {
        var current = items
        guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
        let source = current[index]
        let copy = MenuBarItemConfig(metric: source.metric, mode: source.mode, channels: source.channels)
        current.insert(copy, at: index + 1)
        write(current)
        return copy
    }

    public func remove(_ id: UUID) {
        write(items.filter { $0.id != id })
    }

    public func removeAll(of metric: MetricKind) {
        write(items.filter { $0.metric != metric })
    }

    /// Replaces an instance in place, matched by identity. Invalid edits are repaired rather than
    /// rejected so a caller can never wedge the list into an unrenderable state.
    public func update(_ item: MenuBarItemConfig) {
        var current = items
        guard let index = current.firstIndex(where: { $0.id == item.id }) else { return }
        current[index] = item.repaired()
        write(current)
    }

    /// Bulk replace, used by "restore defaults" and by tests.
    public func replaceAll(with newItems: [MenuBarItemConfig]) {
        write(newItems.map { $0.repaired() })
    }

    // MARK: - Persistence

    private func write(_ newItems: [MenuBarItemConfig]) {
        cache = newItems
        guard let data = try? JSONEncoder().encode(newItems) else { return }
        defaults.set(data, forKey: Self.itemsKey)
    }

    /// Decodes and repairs. A stored item whose mode was retired is repaired to the metric's
    /// defaults, never dropped: a user's menu bar must not lose an entry because of a schema change.
    private func decode() -> [MenuBarItemConfig] {
        guard let data = defaults.data(forKey: Self.itemsKey),
              let stored = try? JSONDecoder().decode([MenuBarItemConfig].self, from: data)
        else { return [] }
        return stored.map { $0.repaired() }
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        // `integer(forKey:)` returns 0 for an absent key, which is exactly "never migrated".
        guard defaults.integer(forKey: Self.schemaVersionKey) < Self.currentSchemaVersion else { return }
        migrateFromLegacyBools()
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
    }

    /// Synthesises one instance per enabled legacy Bool, in `MetricKind.allCases` order — which is
    /// the same order as the retired static `Spec` array, so the migrated menu bar is created in
    /// the order the user already had.
    ///
    /// Each instance takes the metric's *current* default mode and channels, which reproduce today's
    /// hardcoded glyphs exactly: migrating an existing install changes nothing on screen.
    private func migrateFromLegacyBools() {
        let enabled = MetricKind.allCases.filter { legacyEnabled($0) }
        write(enabled.map { MenuBarItemConfig(metric: $0) })
    }

    /// Reads one frozen legacy key.
    ///
    /// ⚠️ `menubar.combined` defaults to ON when absent — the "SS" item shipped enabled via
    /// `register(defaults:)`. `UserDefaults.bool` returns false for an absent key, so relying on it
    /// would migrate every never-configured install to an EMPTY menu bar. Absence is resolved here
    /// rather than through `register(defaults:)`, so migration cannot depend on whether the app's
    /// registration has run yet.
    private func legacyEnabled(_ metric: MetricKind) -> Bool {
        guard let key = Self.legacyKeys[metric] else { return false }
        if defaults.object(forKey: key) == nil { return metric == .combined }
        return defaults.bool(forKey: key)
    }
}
