//
//  File:      SiliconScopeApp.swift
//  Created:   2026-06-08
//  Updated:   2026-09-04
//  Developer: Kennt Kim / Calida Lab
//  Overview:  App entry point. Declares the full dashboard Window and Settings, backed by one
//             shared SiliconScopeMonitor. The menu-bar items are NOT scenes here — they're AppKit
//             NSStatusItems owned by MetricBarController, so each stays individually toggleable.
//  Notes:     Runs as an SPM executable (xcrun swift run SiliconScope); activation
//             policy is set to .regular at runtime so the window + Dock icon appear
//             without a bundled Info.plist. A proper .app bundle comes in packaging.
//             Icon is loaded via loadAppIcon() — never SwiftPM's Bundle.module, whose
//             generated accessor fatalErrors when the flat resource bundle is not a
//             valid bundle (crashes on macOS 27's stricter bundle validation).
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SiliconScopeCore

extension Notification.Name {
    /// Posted by menu-bar dropdowns to open Settings; handled by SettingsOpenerBridge.
    static let openSiliconScopeSettings = Notification.Name("ai.calidalab.SiliconScope.openSettings")
    /// Posted by the "Open Recording…" command (carries the .ssrec URL); handled by DashboardContainer.
    static let openSiliconScopeRecording = Notification.Name("ai.calidalab.SiliconScope.openRecording")
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

/// Keeps the app alive when the dashboard window is closed — it lives on in the menu bar — instead
/// of quitting the whole app (the macOS default for the last-window-closed). Reopens the dashboard
/// on a Dock-icon click. This is the right behavior for a menu-bar-resident monitor (issue #13).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// False when macOS launched us as a login item rather than the user opening the app. A login
    /// launch must come up quietly: no window pulled to the front, no focus stolen (#51).
    /// Defaults to `true` so that if a window somehow appears before this is read, behaviour is
    /// the familiar user-launch one rather than a silent surprise.
    @MainActor private(set) static var isDefaultLaunch = true

    /// Everything that makes SiliconScope a menu-bar monitor starts HERE, at app launch — never
    /// from a window. The menu-bar items are reconciled from the monitor loop, so hanging that
    /// loop off the dashboard's `onAppear` meant a login-launched app showed a Dock icon and an
    /// empty menu bar until the user clicked the icon to summon a window (#51). Fleet discovery
    /// and share mode had the same dependency, so a Mac set to share itself stayed invisible to
    /// the fleet for the same reason.
    func applicationDidFinishLaunching(_ note: Notification) {
        let isDefault = (note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        MainActor.assumeIsolated {
            Self.isDefaultLaunch = isDefault
            startAppServices()
            // Pull the app forward only when the USER opened it — a login launch must not jump in
            // front of whatever they are actually doing (#51). This decision lives here rather
            // than in the window's onAppear because **onAppear runs FIRST** (measured: onAppear →
            // didFinishLaunching → startAppServices), so the window cannot yet know how the app
            // was launched. By this point the window, if there is one, already exists.
            if isDefault { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { openMainDashboard() } }
        return true
    }
}

/// Brings up the parts of the app that have nothing to do with a window: the Dock-icon policy, the
/// sampling loop that feeds the menu-bar items, fleet discovery, and share mode. Idempotent —
/// `SiliconScopeMonitor.start()` guards on its own loop task — so an extra call is harmless.
@MainActor func startAppServices() {
    applyDockIconPolicy()
    if let icon = SiliconScopeApp.loadAppIcon() {
        NSApplication.shared.applicationIconImage = icon
    }
    // The monitor is the one thing that must come up right here: the menu-bar items are
    // reconciled from its loop, which is why hanging it off a window left a login-launched app
    // with an empty menu bar (#51). start() only spawns a task, so it cannot stall the launch.
    let monitor = SiliconScopeMonitor.shared
    monitor.start()

    // ⚠️ Fleet startup must NOT run inside applicationDidFinishLaunching. FleetDiscovery.start()
    // calls emit() synchronously, which reads each paired machine's token through
    // SecItemCopyMatching — a blocking call into securityd, and one that can sit behind an access
    // prompt macOS cannot present until the app has finished launching. Doing it on the launch
    // path deadlocked the launch outright: no window, no menu bar, no status items at all
    // (measured with `sample`: the main thread parked in mach_msg beneath SecItemCopyMatching
    // while SecurityAgent waited). Share mode has the same exposure — it owns a keychain of its
    // own (#34). Both run on the NEXT main-actor turn: AppKit gets to finish launching, and
    // neither waits for a window, so #51 still holds.
    Task { @MainActor in
        // This Mac is always the first Fleet-overview tile: feed the live monitor to the fleet
        // aggregator so it samples this Mac on the same cadence as remote agents.
        let fleet = FleetMonitor.shared
        fleet.localProvider = {
            let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            return monitor.machineMetricsMac(machineId: "local", hostname: host,
                                             osName: os, agentVersion: "local")
        }
        // Discovery still starts as early as it safely can: mDNS takes a moment, so machines are
        // already listed by the time the user opens the Devices sidebar.
        fleet.start()

        // Share this Mac to the fleet when enabled (Settings toggle, or SSCOPE_SHARE=1 for dev).
        MacAgentController.shared.configure(monitor: monitor)
        if UserDefaults.standard.bool(forKey: "shareThisMac")
            || ProcessInfo.processInfo.environment["SSCOPE_SHARE"] == "1" {
            MacAgentController.shared.startIfConfigured()
        }
    }
}

/// Sets the Dock-icon presence from the user's "Show Dock icon" setting (default on). Off =
/// `.accessory` — a pure menu-bar utility with no Dock icon (the dashboard still opens from any
/// menu-bar dropdown). A single stable policy, not a per-window toggle, so the icon never flickers.
@MainActor func applyDockIconPolicy() {
    let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    NSApplication.shared.setActivationPolicy(showDock ? .regular : .accessory)
}

@main
struct SiliconScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = SiliconScopeMonitor.shared
    // Fleet — machines are discovered automatically via mDNS ("_sscope-agent._tcp"); no hardcoded
    // endpoints. FleetMonitor owns discovery + polling behind the MachineMetrics boundary.
    @State private var fleet = FleetMonitor.shared
    // Which device the single window's detail pane shows. Optional to satisfy List(selection:).
    @State private var deviceSelection: DeviceSelection? = .thisMac

    // The combined "SS" menu-bar item and all per-metric items are AppKit NSStatusItems managed
    // by MetricBarController (driven from the monitor loop), so each can be toggled — including
    // hiding the combined SS on notch-limited menu bars. (SwiftUI's MenuBarExtra can't: its
    // isInserted: init has no custom-label form for the live glyph, and toggling it loops the
    // main menu.) The monitor is started from the main window's onAppear at launch.
    init() { UIScale.registerDefaults() }

    var body: some Scene {
        mainWindow
            // Zoom lives in the View menu as well as on ⌘+/⌘−/⌘0, because the shortcut alone is
            // not reachable: with "Show Dock icon" off the app runs as .accessory and has no menu
            // bar at all — and Settings actively recommends that mode. Settings carries the same
            // control (design-system D1, requirement 1).
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Zoom In")  { UIScale.step(+1) }.keyboardShortcut("+", modifiers: .command)
                    // "+" is really ⌘⇧= on a US layout, so bind the unshifted key too — that is
                    // what people actually press, and what Safari/Xcode/Finder accept. Hidden so
                    // the View menu shows one Zoom In, not two.
                    Button("Zoom In")  { UIScale.step(+1) }
                        .keyboardShortcut("=", modifiers: .command).hidden()
                    Button("Zoom Out") { UIScale.step(-1) }.keyboardShortcut("-", modifiers: .command)
                    Button("Actual Size") { UIScale.reset() }.keyboardShortcut("0", modifiers: .command)
                    Divider()
                }
            }
        Settings { SettingsView() }
    }

    /// The single app window: a Devices sidebar (This Mac + discovered fleet agents) driving a
    /// detail dashboard. Replaces the old separate dashboard + ⌘⇧F Fleet windows.
    private var mainWindow: some Scene {
        Window("SiliconScope", id: "siliconscope-main") {
            SiliconScopeRootView(monitor: monitor, fleet: fleet, selection: $deviceSelection)
                // This window's surface is unconditionally dark — `Theme.bg` is a fixed near-black,
                // not a dynamic system color — but nothing ever told AppKit that. On a light-mode
                // Mac the chrome AppKit draws for the window therefore rendered light over it: the
                // sidebar-toggle button became a pale chip and the title text dark-on-dark (#50).
                // Pinning the appearance makes every system-drawn control match the surface we
                // paint. Scoped to this window deliberately: `NSApp.appearance` would also override
                // the status button's effectiveAppearance, which MetricBarController reads to pick
                // menu-bar ink from the REAL menu bar background.
                .preferredColorScheme(.dark)
                .background(SettingsOpenerBridge())   // routes dropdown "Settings" → openSettings()
                .onAppear {
                    // Only the window's own business lives here. Everything app-wide — the monitor
                    // loop, the Dock-icon policy, fleet discovery, share mode — starts in
                    // `startAppServices()` from `applicationDidFinishLaunching`, because a
                    // menu-bar app must work with no window at all (#51).
                    //
                    // Closing the window hides it (we stay in the menu bar) rather than destroying
                    // it, so openMainDashboard() can bring the same window back. Pairs with the
                    // AppDelegate's terminate-after-last-window = false.
                    NSApplication.shared.windows
                        .first { $0.identifier?.rawValue == "siliconscope-main" }?
                        .isReleasedWhenClosed = false
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                    .disabled(!UpdaterController.shared.canCheck)
            }
            CommandGroup(after: .newItem) {
                Button("Open Recording…") { Self.openRecordingPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    /// File → Open Recording…: pick a .ssrec and hand it to DashboardContainer via notification.
    private static func openRecordingPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let ssrec = UTType(filenameExtension: "ssrec") { panel.allowedContentTypes = [ssrec] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NotificationCenter.default.post(name: .openSiliconScopeRecording, object: nil, userInfo: ["url": url])
    }


    /// Resolves the app icon without ever touching SwiftPM's `Bundle.module`.
    /// `Bundle.module`'s generated accessor calls `fatalError` when its resource
    /// bundle is not recognized as a bundle; the SwiftPM bundle is a flat folder
    /// with no Info.plist, which macOS 27's stricter validation rejects -> crash.
    fileprivate static func loadAppIcon() -> NSImage? {
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
