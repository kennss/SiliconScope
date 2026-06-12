//
//  File:      MenuBarView.swift
//  Created:   2026-06-08
//  Updated:   2026-06-12
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Compact menu-bar popover content: the essentials at a glance (E/P, mem,
//             GPU, bandwidth, power, die temp) plus Quit.
//  Notes:     Shares the same KtopMonitor as the full window, so both stay in sync.
//             "compactGPUMode" (UserDefaults) swaps the full readout for a single
//             GPU-focused line: GPU% / GPU W / GPU GB/s / die °C.
//
import SwiftUI
import AppKit
import KtopCore

struct MenuBarView: View {
    let monitor: KtopMonitor
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("compactGPUMode") private var compactGPU = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 9) {
            if compactGPU {
                compactGPURow(snapshot)
            } else {
                fullReadout(snapshot)
            }

            Divider()
            HStack {
                Button("Settings…") { openSettings() }
                Spacer()
                Button("Quit WhisPlayInfo") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: compactGPU ? 340 : 270)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    /// Single-line GPU-focused readout: GPU% / GPU W / GPU bandwidth / die °C.
    @ViewBuilder
    private func compactGPURow(_ s: SystemSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("GPU")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            compactValue(String(format: "%.0f%%", s.gpu.usagePercent), color: Theme.heat(s.gpu.usage))
            compactSeparator
            compactValue(String(format: "%.1f W", s.power.gpuWatts))
            compactSeparator
            compactValue(String(format: "%.0f GB/s", s.bandwidth.gpuGBs))
            compactSeparator
            compactValue(formatTemperature(s.temperature.cpuCelsius, fahrenheit: fahrenheit),
                         color: monitor.gpuThrottling ? Theme.heat(1) : Theme.text)
            if monitor.gpuThrottling {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.heat(1))
                    .help("GPU thermal throttling")
            }
        }
    }

    private func compactValue(_ text: String, color: Color = Theme.text) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
    }

    private var compactSeparator: some View {
        Text("·").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
    }

    /// The standard multi-line readout (E/P, memory, GPU, ANE, bandwidth, power, temps).
    @ViewBuilder
    private func fullReadout(_ snapshot: SystemSnapshot) -> some View {
        Text("WhisPlayInfo")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.accent)

        KV(key: "Workload", value: monitor.bottleneck.label, valueColor: monitor.bottleneck.color)

        Bar(label: "E", value: snapshot.cpu.eUsage,
            detail: String(format: "%.0f%%", snapshot.cpu.eUsagePercent))
        Bar(label: "P", value: snapshot.cpu.pUsage,
            detail: String(format: "%.0f%%", snapshot.cpu.pUsagePercent))
        Bar(label: "MEM", value: snapshot.memory.usedFraction,
            detail: String(format: "%.0f%%", snapshot.memory.usedPercent))

        Divider()
        KV(key: "GPU", value: String(format: "%.0f%% · %.1f W", snapshot.gpu.usagePercent, snapshot.power.gpuWatts))
        KV(key: "ANE", value: String(format: "%.1f W", snapshot.power.aneWatts))
        KV(key: "Media", value: String(format: "%.1f GB/s", snapshot.bandwidth.mediaGBs))
        KV(key: "Mem BW", value: String(format: "%.0f GB/s", snapshot.bandwidth.totalGBs))
        KV(key: "SoC power", value: String(format: "%.1f W", snapshot.power.socWatts))
        KV(key: "CPU temp", value: formatTemperature(snapshot.temperature.cpuCelsius, fahrenheit: fahrenheit))
        if snapshot.temperature.hasBattery {
            KV(key: "Battery", value: formatTemperature(snapshot.temperature.batteryCelsius, fahrenheit: fahrenheit))
        }
    }
}
