//
//  File:      MetricBarController.swift
//  Created:   2026-06-19
//  Updated:   2026-06-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  iStat-style per-metric menu-bar items via AppKit NSStatusItem. SwiftUI's
//             MenuBarExtra can't do dynamic toggling here (a conditional scene won't compile
//             — SceneBuilder has no buildOptional — and `isInserted:` triggers a main-menu
//             update loop), so each toggled metric gets a real NSStatusItem with a live
//             glyph and an NSPopover hosting its SwiftUI dropdown.
//  Notes:     Driven from the monitor loop via sync(monitor:): it adds/removes items as the
//             per-metric UserDefaults toggles flip and refreshes each glyph every tick. The
//             combined "SS" glyph stays a SwiftUI MenuBarExtra (always on).
//
import AppKit
import SwiftUI
import SiliconScopeCore

@MainActor
final class MetricBarController: NSObject {
    static let shared = MetricBarController()

    private struct Spec {
        let id: String
        let key: String
        let glyph: (SiliconScopeMonitor, Bool) -> NSImage
        let dropdown: (SiliconScopeMonitor) -> AnyView
    }

    private struct Entry { let item: NSStatusItem; let popover: NSPopover }

    private var entries: [String: Entry] = [:]
    private weak var monitor: SiliconScopeMonitor?

    private static let specs: [Spec] = [
        Spec(id: "cpu", key: "menubar.cpu",
             glyph: { m, dark in
                MenuBarGlyph.bars(label: "CPU",
                                  values: [m.snapshot.cpu.eUsage, m.snapshot.cpu.pUsage],  // left E, right P
                                  colors: [MetricPalette.eCPU, MetricPalette.pCPU], dark: dark)
             },
             dropdown: { m in AnyView(CPUMenuDropdown(monitor: m)) }),

        Spec(id: "gpu", key: "menubar.gpu",
             glyph: { m, dark in
                MenuBarGlyph.bars(label: "GPU",
                                  values: [m.snapshot.gpu.usage,
                                           min(1, m.snapshot.bandwidth.mediaGBs / max(m.mediaPeakGBs, 0.5)),
                                           min(1, m.snapshot.power.aneWatts / max(m.anePeakWatts, 0.1))],
                                  colors: [MetricPalette.gpu, MetricPalette.media, MetricPalette.ane], dark: dark)
             },
             dropdown: { m in AnyView(GPUMenuDropdown(monitor: m)) }),

        Spec(id: "mem", key: "menubar.mem",
             glyph: { m, dark in
                MenuBarGlyph.twoLine(label: "MEM",
                                     prefix1: "U:", value1: iStatGB(m.snapshot.memory.usedGB),
                                     prefix2: "F:", value2: iStatGB(m.snapshot.memory.freeGB),
                                     dark: dark, reserveValue: "999.9 GB")
             },
             dropdown: { m in AnyView(MEMMenuDropdown(monitor: m)) }),

        Spec(id: "net", key: "menubar.net",
             glyph: { m, dark in
                MenuBarGlyph.twoLine(label: "NET",
                                     prefix1: "↓", value1: iStatRate(m.snapshot.network.downloadBytesPerSec),
                                     prefix2: "↑", value2: iStatRate(m.snapshot.network.uploadBytesPerSec),
                                     dark: dark, reserveValue: "999 MB")
             },
             dropdown: { m in AnyView(NETMenuDropdown(monitor: m)) }),

        Spec(id: "ssd", key: "menubar.ssd",
             glyph: { m, dark in
                MenuBarGlyph.twoLine(label: "SSD",
                                     prefix1: "U:", value1: iStatBytes(m.snapshot.disk.totalBytes - m.snapshot.disk.freeBytes),
                                     prefix2: "F:", value2: iStatBytes(m.snapshot.disk.freeBytes),
                                     dark: dark, reserveValue: "999.9 GB")
             },
             dropdown: { m in AnyView(SSDMenuDropdown(monitor: m)) }),

        Spec(id: "sensors", key: "menubar.sensors",
             glyph: { m, dark in
                let f = UserDefaults.standard.bool(forKey: "temperatureFahrenheit")
                let t = m.snapshot.temperature
                let cpu = t.cpuMaxCelsius > 0 ? t.cpuMaxCelsius : t.cpuCelsius
                let (p2, v2): (String, Double) = t.gpuCelsius > 0 ? ("G", t.gpuCelsius) : ("B", t.batteryCelsius)
                return MenuBarGlyph.twoLine(label: "SEN",
                                            prefix1: "C", value1: tempGlyphValue(cpu, f),
                                            prefix2: p2, value2: tempGlyphValue(v2, f),
                                            dark: dark, reserveValue: "99°")
             },
             dropdown: { m in AnyView(SensorsMenuDropdown(monitor: m)) }),

        Spec(id: "battery", key: "menubar.battery",
             glyph: { m, dark in
                let b = m.snapshot.battery
                return MenuBarGlyph.battery(percent: b.percent, charging: b.isCharging,
                                            plugged: b.isPluggedIn, dark: dark)
             },
             dropdown: { m in AnyView(BatteryMenuDropdown(monitor: m)) }),
    ]

    /// Called each monitor tick: reconcile items with toggles, refresh glyphs.
    func sync(monitor: SiliconScopeMonitor) {
        self.monitor = monitor
        for spec in Self.specs {
            if UserDefaults.standard.bool(forKey: spec.key) {
                if entries[spec.id] == nil { entries[spec.id] = makeEntry(spec) }
                if let button = entries[spec.id]?.item.button {
                    // Decide ink from the STATUS BUTTON's appearance, not the app's. The button
                    // adopts the menu bar's real light/dark background (wallpaper + fullscreen),
                    // so black ink no longer vanishes on a dark menu bar while the app is in
                    // Light Mode (reported: text invisible except over a light wallpaper).
                    let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    button.image = spec.glyph(monitor, dark)
                }
            } else if let e = entries[spec.id] {
                e.popover.performClose(nil)
                NSStatusBar.system.removeStatusItem(e.item)
                entries[spec.id] = nil
            }
        }
    }

    private func makeEntry(_ spec: Spec) -> Entry {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        popover.behavior = .transient
        if let m = monitor {
            popover.contentViewController = NSHostingController(rootView: spec.dropdown(m))
        }
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(spec.id)
        }
        return Entry(item: item, popover: popover)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let e = entries[id] else { return }
        if e.popover.isShown {
            e.popover.performClose(nil)
        } else {
            // Only one menu-bar dropdown open at a time, like every other status item: close
            // any other per-metric popover before opening this one. (Each NSPopover is .transient
            // but transient dismissal doesn't fire reliably when the click lands on another of
            // our own status buttons, so enforce it explicitly.)
            closeAllPopovers(except: id)
            closeCombinedPopover()
            e.popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            e.popover.contentViewController?.view.window?.makeKey()
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
    func closeAllPopovers(except keepID: String? = nil) {
        for (id, e) in entries where id != keepID && e.popover.isShown {
            e.popover.performClose(nil)
        }
    }
}
