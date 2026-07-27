//
//  File:      MenuBarItemsModel.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The app's observable façade over Core's `MenuBarItemStore` (#27, phase 4a). The store
//             is deliberately UI-free — Core may not carry SwiftUI or main-actor isolation — so the
//             SwiftUI-facing half (publishing, and the `Binding<Bool>` that card pins expect) lives
//             here instead.
//  Notes:     Single instance: `MetricBarController`, the dashboard's card pins and Settings must
//             all see the same list, and the status items are process-wide anyway.
//             `pin(_:)` is the 1:N replacement for the retired `@AppStorage("menubar.*")` Bools:
//             ON is DERIVED from "has ≥ 1 instance", never stored, so it can't disagree with the
//             list it is supposed to describe.
//             `items` is a cached array read on the 1 Hz tick — no JSON decoding on that path.
//
import SwiftUI
import SiliconScopeCore

@MainActor
final class MenuBarItemsModel: ObservableObject {
    static let shared = MenuBarItemsModel()

    private let store: MenuBarItemStore

    /// The current items, republished on every mutation.
    @Published private(set) var items: [MenuBarItemConfig] = []

    init(store: MenuBarItemStore = MenuBarItemStore()) {
        self.store = store
        self.items = store.items
    }

    // MARK: - Reading

    func isPinned(_ metric: MetricKind) -> Bool { store.isPinned(metric) }

    /// A card's menu-bar pin. Reading is derived state; writing appends one instance or removes
    /// every instance of the metric (docs/design-system.md §4.4).
    func pin(_ metric: MetricKind) -> Binding<Bool> {
        Binding(get: { self.isPinned(metric) },
                set: { self.setPinned($0, for: metric) })
    }

    // MARK: - Mutating

    func setPinned(_ on: Bool, for metric: MetricKind) {
        store.setPinned(on, for: metric)
        publish()
    }

    @discardableResult
    func append(_ metric: MetricKind) -> MenuBarItemConfig {
        let item = store.append(metric)
        publish()
        return item
    }

    func duplicate(_ id: UUID) {
        store.duplicate(id)
        publish()
    }

    func remove(_ id: UUID) {
        store.remove(id)
        publish()
    }

    func update(_ item: MenuBarItemConfig) {
        store.update(item)
        publish()
    }

    private func publish() { items = store.items }
}
