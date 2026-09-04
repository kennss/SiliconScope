//
//  File:      MetricBarController.swift
//  Created:   2026-06-19
//  Updated:   2026-09-04
//  Developer: Kennt Kim / Calida Lab
//  Overview:  iStat-style per-metric menu-bar items via AppKit NSStatusItem. SwiftUI's
//             MenuBarExtra can't do dynamic toggling here (a conditional scene won't compile
//             — SceneBuilder has no buildOptional — and `isInserted:` triggers a main-menu
//             update loop), so each configured item gets a real NSStatusItem with a live
//             glyph and an NSPopover hosting its SwiftUI dropdown.
//  Notes:     Driven from the monitor loop via sync(monitor:): it reconciles the live status items
//             against `MenuBarItemsModel.shared.items` and refreshes each glyph.
//             As of #27 phase 4a the item list is DATA, not code: what to draw comes from a
//             `MenuBarItemConfig` and is rendered by `MenuBarItemRenderer`. Entries are keyed by
//             the config's UUID, not by metric, because one metric may appear several times.
//             ⚠️ Two costs this file must not reintroduce (docs/energy-optimization.md, §4.5):
//             glyphs re-rasterize only when their signature changes, and a popover's SwiftUI
//             content is built on FIRST CLICK — building it eagerly kept up to 8 hosting
//             controllers, and their subscribers, resident before any dropdown was ever opened.
//
import AppKit
import SwiftUI
import SiliconScopeCore

@MainActor
final class MetricBarController: NSObject {
    static let shared = MetricBarController()

    private struct Entry { let item: NSStatusItem; let popover: NSPopover; var lastSig: String? }

    private var entries: [UUID: Entry] = [:]
    private weak var monitor: SiliconScopeMonitor?

    /// Called each monitor tick: reconcile items with the configured list, refresh glyphs.
    func sync(monitor: SiliconScopeMonitor) {
        self.monitor = monitor
        let configs = MenuBarItemsModel.shared.items
        let live = Set(configs.map(\.id))

        // Items the user removed (or that a pin turned off).
        for (id, entry) in entries where !live.contains(id) {
            entry.popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(entry.item)
            entries[id] = nil
        }

        for config in configs {
            if entries[config.id] == nil { entries[config.id] = makeEntry(config) }
            guard let button = entries[config.id]?.item.button else { continue }
            // Decide ink from the STATUS BUTTON's appearance, not the app's. The button
            // adopts the menu bar's real light/dark background (wallpaper + fullscreen),
            // so black ink no longer vanishes on a dark menu bar while the app is in
            // Light Mode (reported: text invisible except over a light wallpaper).
            let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Only re-rasterize when the glyph's pixels would actually change — reassigning
            // button.image forces an NSStatusItem replicant re-render every time (FIX 3).
            let sig = MenuBarItemRenderer.signature(config, monitor, dark: dark)
            if entries[config.id]?.lastSig != sig {
                button.image = MenuBarItemRenderer.glyph(config, monitor, dark: dark)
                entries[config.id]?.lastSig = sig
            }
        }
    }

    /// Creates the status item WITHOUT its SwiftUI content — see `buttonClicked`.
    private func makeEntry(_ config: MenuBarItemConfig) -> Entry {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS owns status-item position: it persists the user's ⌘-drag order per autosave name,
        // which is why the model carries no order field of its own.
        item.autosaveName = config.autosaveName
        let popover = NSPopover()
        popover.behavior = .transient
        // The dropdown paints `Theme.bg` — a fixed near-black — so the chrome AppKit draws around
        // it must be dark for the same reason the main window's is (#50). Left to inherit, a
        // light-mode Mac drew a pale arrow and border into a near-black panel. Set per popover
        // rather than on `NSApp`, which would also override the status button's effectiveAppearance
        // that `refresh()` reads to pick menu-bar ink from the real menu bar background.
        popover.appearance = NSAppearance(named: .darkAqua)
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(config.id.uuidString)
        }
        return Entry(item: item, popover: popover, lastSig: nil)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let entry = entries[id] else { return }
        if entry.popover.isShown {
            entry.popover.performClose(nil)
            return
        }
        // Build the dropdown on first open, then keep it: a hosting controller and its
        // subscribers should not exist for a panel the user has never looked at.
        if entry.popover.contentViewController == nil, let m = monitor,
           let config = MenuBarItemsModel.shared.items.first(where: { $0.id == id }) {
            entry.popover.contentViewController = NSHostingController(rootView: MenuBarItemRenderer.dropdown(config, m))
        }
        // Only one menu-bar dropdown open at a time, like every other status item: close
        // any other per-metric popover before opening this one. (Each NSPopover is .transient
        // but transient dismissal doesn't fire reliably when the click lands on another of
        // our own status buttons, so enforce it explicitly.)
        closeAllPopovers(except: id)
        closeCombinedPopover()
        entry.popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        if let window = entry.popover.contentViewController?.view.window {
            // A status-item popover does NOT inherit the status bar's Spaces behavior. Measured
            // on macOS 26.5: NSStatusBarWindow carries `.fullScreenAuxiliary`, but the
            // _NSPopoverWindow AppKit creates for us defaults to `.ignoresCycle` alone. With no
            // Space-joining flag, macOS keeps the dropdown on the app's own Space, so while a
            // full-screen app is frontmost the icon still responds but the panel opens offscreen
            // back in Space 1 (github.com/kennss/SiliconScope#49). `.fullScreenAuxiliary` lets it
            // share a full-screen Space; `.moveToActiveSpace` makes it follow the user instead of
            // pinning to every Space the way `.canJoinAllSpaces` would. Inserted rather than
            // assigned so AppKit's own flags survive, and applied after show() because the
            // backing window does not exist until then — it is reused for later opens.
            //
            // ⚠️ The re-order is load-bearing, not tidying. `.moveToActiveSpace` is evaluated when
            // the window is ORDERED FRONT, and show() has already placed it by the time we can
            // reach it — so inserting the flag alone left the very first dropdown of a session
            // stranded on the app's own Space while every later one worked (measured: identical
            // `isShown`/`isVisible`/`collectionBehavior`, popover absent from the captured
            // full-screen Space). Ordering it front again applies the flag we just set.
            window.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Dismiss the combined "SS" MenuBarExtra popover. SwiftUI has no public API to close a
    /// MenuBarExtra from outside, so we order out its backing window, identified by its private
    /// class name "MenuBarExtraWindow" (verified at runtime). Our own per-metric popovers are
    /// NSPopover-backed and the dashboard is an AppKitWindow, so neither is affected.
    private func closeCombinedPopover() {
        for w in NSApp.windows
        where w.isVisible && String(describing: type(of: w)).contains("MenuBarExtraWindow") {
            w.orderOut(nil)
        }
    }

    /// Close every per-metric popover (optionally keeping one open). Called before opening one,
    /// and when the combined "SS" popover appears, so SiliconScope's menu-bar items behave like
    /// standard mutually-exclusive dropdowns instead of stacking up.
    func closeAllPopovers(except keepID: UUID? = nil) {
        for (id, e) in entries where id != keepID && e.popover.isShown {
            e.popover.performClose(nil)
        }
    }
}
