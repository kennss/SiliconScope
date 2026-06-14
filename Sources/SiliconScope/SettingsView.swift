//
//  File:      SettingsView.swift
//  Created:   2026-06-08
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Preferences window (Cmd+,). Refresh cadence, temperature unit, and the
//             menu-bar compact GPU mode, persisted in UserDefaults via @AppStorage.
//  Notes:     Keys: "refreshInterval" (seconds), "temperatureFahrenheit" (Bool),
//             "compactGPUMode" (Bool). SiliconScopeMonitor reads refreshInterval each loop;
//             temperature views read the unit; MenuBarView reads compactGPUMode. All
//             update live without restart.
//
import SwiftUI

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval = 1.0
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("compactGPUMode") private var compactGPU = false
    @AppStorage("aiRuntimeAPIEnabled") private var aiRuntimeAPIEnabled = false
    @AppStorage("aiRuntimeOllamaPort") private var ollamaPort = 11434
    @AppStorage("aiRuntimeLMStudioPort") private var lmStudioPort = 1234

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
            }

            Section {
                Toggle("Connect to local AI runtimes", isOn: $aiRuntimeAPIEnabled)
                if aiRuntimeAPIEnabled {
                    TextField("Ollama port", value: $ollamaPort, format: .number.grouping(.never))
                    TextField("LM Studio port", value: $lmStudioPort, format: .number.grouping(.never))
                }
            } header: {
                Text("Local AI runtime API (opt-in)")
            } footer: {
                Text("Reads the loaded model, processor split, and tokens/sec from AI runtimes on 127.0.0.1. Nothing leaves your Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: aiRuntimeAPIEnabled ? 360 : 290)
    }
}
