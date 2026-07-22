//
//  File:      SettingsView.swift
//  Created:   2026-06-08
//  Updated:   2026-07-02
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Preferences window (Cmd+,). Refresh cadence, temperature unit, menu-bar
//             compact GPU mode, launch-at-login, threshold alerts, and the AI runtime API
//             — persisted in UserDefaults via @AppStorage.
//  Notes:     Keys: "refreshInterval" (s), "temperatureFahrenheit" (Bool),
//             "compactGPUMode" (Bool), "notificationsEnabled" (Bool). Launch-at-login is
//             owned by SMAppService (LoginItem), not UserDefaults. SiliconScopeMonitor
//             reads refreshInterval + notificationsEnabled each loop. All update live.
//
import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval = 1.0
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("compactGPUMode") private var compactGPU = false
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("aiRuntimeAPIEnabled") private var aiRuntimeAPIEnabled = false
    @AppStorage("aiRuntimeOllamaPort") private var ollamaPort = 11434
    @AppStorage("aiRuntimeLMStudioPort") private var lmStudioPort = 1234
    @AppStorage("aiRuntimeOmlxPort") private var omlxPort = 8000
    @AppStorage("aiRuntimeOmlxApiKey") private var omlxApiKey = ""
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("showWarningBanner") private var showWarningBanner = true
    // Per-metric menu-bar items — same keys the ⬚ pin on each dashboard card writes, so the
    // two stay in sync (MetricBarController reconciles status items from these each tick).
    @AppStorage("menubar.combined") private var mbCombined = true
    @AppStorage("menubar.cpu") private var mbCPU = false
    @AppStorage("menubar.gpu") private var mbGPU = false
    @AppStorage("menubar.mem") private var mbMEM = false
    @AppStorage("menubar.net") private var mbNET = false
    @AppStorage("menubar.ssd") private var mbSSD = false
    @AppStorage("menubar.sensors") private var mbSEN = false
    @AppStorage("menubar.battery") private var mbBAT = false
    @AppStorage("shareThisMac") private var shareThisMac = false
    @State private var autoUpdate = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var agentToken: String?

    var body: some View {
        Form {
            Section {
                Picker("Refresh interval", selection: $refreshInterval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                }
                Picker("Temperature unit", selection: $fahrenheit) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
                Toggle("Compact GPU mode (menu bar)", isOn: $compactGPU)
                Toggle("Show Dock icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in applyDockIconPolicy() }
            } footer: {
                Text("Turn off the Dock icon to run SiliconScope as a pure menu-bar utility — the dashboard still opens from any menu-bar item's dropdown.")
            }

            Section {
                Toggle("Combined (SS)", isOn: $mbCombined)
                Divider()
                Toggle("CPU", isOn: $mbCPU)
                Toggle("GPU / Media / Neural", isOn: $mbGPU)
                Toggle("Memory", isOn: $mbMEM)
                Toggle("Network", isOn: $mbNET)
                Toggle("Disk (SSD)", isOn: $mbSSD)
                Toggle("Sensors", isOn: $mbSEN)
                Toggle("Battery", isOn: $mbBAT)
            } header: {
                Text("Menu bar items")
            } footer: {
                Text("Show any metric as its own menu-bar item with a live glyph + dropdown (also toggleable with the ⬚ on each dashboard card). Turn off Combined (SS) to free a menu-bar slot on notch-limited Macs — Settings stays reachable from any item's dropdown.")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.setEnabled(on) }
                Toggle("Show warning banner", isOn: $showWarningBanner)
                Toggle("Alert notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, on in if on { Notifier.requestAuthorization() } }
                if UpdaterController.shared.canCheck {
                    Toggle("Automatically check for updates", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, on in UpdaterController.shared.automaticallyChecks = on }
                    Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                }
            } header: {
                Text("Startup & alerts")
            } footer: {
                Text("On GPU thermal throttle or memory pressure, the affected card's border turns amber/red. The in-app warning banner is on by default (turn it off above); optional macOS notifications fire once per event.")
            }

            Section {
                Toggle("Connect to local AI runtimes", isOn: $aiRuntimeAPIEnabled)
                if aiRuntimeAPIEnabled {
                    TextField("Ollama port", value: $ollamaPort, format: .number.grouping(.never))
                    TextField("LM Studio port", value: $lmStudioPort, format: .number.grouping(.never))
                    TextField("oMLX port", value: $omlxPort, format: .number.grouping(.never))
                    TextField("oMLX API Key (optional)", text: $omlxApiKey)
                }
            } header: {
                Text("Local AI runtime API (opt-in)")
            } footer: {
                Text("Reads the loaded model, processor split, and tokens/sec from AI runtimes on 127.0.0.1. Nothing leaves your Mac.")
            }

            Section {
                Toggle("Share this Mac to Fleet", isOn: $shareThisMac)
                    .onChange(of: shareThisMac) { _, on in
                        if on {
                            MacAgentController.shared.startIfConfigured()
                            Task { try? await Task.sleep(for: .seconds(1)); agentToken = MacAgentController.shared.pairingToken }
                        } else {
                            MacAgentController.shared.stop()
                            agentToken = nil
                        }
                    }
                if shareThisMac {
                    if let token = agentToken {
                        LabeledContent("Pairing token") {
                            HStack(spacing: 6) {
                                Text(token)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(token, forType: .string)
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless).help("Copy token")
                            }
                        }
                    } else {
                        Text("Starting…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Fleet")
            } footer: {
                Text("Let other Macs on your network monitor this Mac, encrypted. Enter this token in their SiliconScope (Fleet sidebar → this Mac → Pair).")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: aiRuntimeAPIEnabled ? 820 : 710)
        .onAppear {
            autoUpdate = UpdaterController.shared.automaticallyChecks
            if shareThisMac { agentToken = MacAgentController.shared.pairingToken }
        }
    }
}
