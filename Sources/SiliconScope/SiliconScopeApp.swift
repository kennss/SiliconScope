//
//  File:      SiliconScopeApp.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  App entry point. Shows a full dashboard Window and a MenuBarExtra (with a
//             live 5-bar MenuBarIcon glyph), both backed by one shared SiliconScopeMonitor.
//  Notes:     Runs as an SPM executable (xcrun swift run SiliconScope); activation
//             policy is set to .regular at runtime so the window + Dock icon appear
//             without a bundled Info.plist. A proper .app bundle comes in packaging.
//             Icon is loaded via loadAppIcon() — never SwiftPM's Bundle.module, whose
//             generated accessor fatalErrors when the flat resource bundle is not a
//             valid bundle (crashes on macOS 27's stricter bundle validation).
//
import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by menu-bar dropdowns to open Settings; handled by SettingsOpenerBridge.
    static let openSiliconScopeSettings = Notification.Name("ai.calidalab.SiliconScope.openSettings")
}

/// Invisible view in the dashboard scene that routes the menu-bar dropdowns' Settings request to
/// SwiftUI's `openSettings`. The dropdowns are AppKit NSPopovers where `@Environment(\.openSettings)`
/// isn't available and `showSettingsWindow:` doesn't surface the window — but a scene-attached view
/// like this one can call openSettings() directly, which does.
private struct SettingsOpenerBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .openSiliconScopeSettings)) { _ in
                openSettings()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

@main
struct SiliconScopeApp: App {
    @State private var monitor = SiliconScopeMonitor()

    // The combined "SS" menu-bar item and all per-metric items are AppKit NSStatusItems managed
    // by MetricBarController (driven from the monitor loop), so each can be toggled — including
    // hiding the combined SS on notch-limited menu bars. (SwiftUI's MenuBarExtra can't: its
    // isInserted: init has no custom-label form for the live glyph, and toggling it loops the
    // main menu.) The monitor is started from the dashboard window's onAppear at launch.
    var body: some Scene {
        dashboardWindow
        Settings { SettingsView() }
    }

    private var dashboardWindow: some Scene {
        Window("SiliconScope", id: "siliconscope-main") {
            DashboardContainer(monitor: monitor)
                .frame(minWidth: 640, minHeight: 600)
                .background(SettingsOpenerBridge())   // routes dropdown "Settings" → openSettings()
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    if let icon = Self.loadAppIcon() {
                        NSApplication.shared.applicationIconImage = icon
                    }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    monitor.start()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                    .disabled(!UpdaterController.shared.canCheck)
            }
        }
    }


    /// Resolves the app icon without ever touching SwiftPM's `Bundle.module`.
    /// `Bundle.module`'s generated accessor calls `fatalError` when its resource
    /// bundle is not recognized as a bundle; the SwiftPM bundle is a flat folder
    /// with no Info.plist, which macOS 27's stricter validation rejects -> crash.
    private static func loadAppIcon() -> NSImage? {
        // Packaged .app: AppIcon.icns sits directly in Contents/Resources.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        // Dev run (`swift run`): it lives inside the SwiftPM resource bundle next to
        // the executable. Resolve the path by hand so we never invoke Bundle.module.
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let url = base.appendingPathComponent("SiliconScope_SiliconScope.bundle/AppIcon.icns")
            if let icon = NSImage(contentsOf: url) { return icon }
        }
        return nil
    }
}
