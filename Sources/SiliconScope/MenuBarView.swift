//
//  File:      MenuBarView.swift
//  Created:   2026-06-08
//  Updated:   2026-06-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Compact menu-bar popover content: the essentials at a glance (E/P, mem,
//             GPU, bandwidth, power, die temp), trend sparklines, top processes, plus
//             "Open Dashboard" (brings the full window forward) / Settings / Quit.
//  Notes:     Shares the same SiliconScopeMonitor as the full window, so both stay in sync.
//             "compactGPUMode" (UserDefaults) swaps the full readout for a single
//             GPU-focused line: GPU% / GPU W / GPU GB/s / die °C.
//             "Open Dashboard" uses openWindow(id: "siliconscope-main") + activate.
//
import SwiftUI
import AppKit
import SiliconScopeCore

struct MenuBarView: View {
    let monitor: SiliconScopeMonitor
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("compactGPUMode") private var compactGPU = false

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 2) {
            if compactGPU {
                compactGPURow(snapshot)
            } else {
                fullReadout(snapshot)
            }

            Divider()
                .padding(.bottom, 2)
            // One full-width primary action, then two equal-width secondary buttons — all
            // share PopoverButtonStyle so they match the cards (panel fill, hairline border,
            // mono label) at a uniform height. "Check for Updates…" lives in Settings.
            VStack(spacing: 7) {
                Button {
                    openMainDashboard()
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                }
                .buttonStyle(PopoverButtonStyle(prominent: true))

                HStack(spacing: 7) {
                    Button("Settings") { openAppSettings() }
                        .buttonStyle(PopoverButtonStyle())
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(PopoverButtonStyle())
                }
            }
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
        Text("SiliconScope")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.accent)

        KV(key: "Workload", value: monitor.bottleneck.label, valueColor: monitor.bottleneck.color)

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

        Divider()
        KV(key: "AI runtime", value: snapshot.aiRuntimeLabel)
        KV(key: "Fits now", value: snapshot.memoryBudget.fitsNow.first?.label ?? "—")

        Divider()
        metricGraphs(snapshot)

        Divider()
        topProcesses(snapshot)
    }

    /// Six trend graphs — same metrics, colors AND normalization as the menu-bar glyph.
    /// Each is plotted on a FIXED Y domain matching its bar (utilization 0...1, ANE/Media
    /// vs their tracked peaks, Mem BW vs the chip ceiling), so a small or flat signal reads
    /// small. Auto-scaling would stretch any series to fill the row — looks exaggerated.
    @ViewBuilder
    private func metricGraphs(_ s: SystemSnapshot) -> some View {
        let c = MenuBarIcon.barColors.map(Color.init(nsColor:))
        Text("TRENDS")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.faint)
        graphRow("CPU", c[0], monitor.history.pCPU, String(format: "%.0f%%", s.cpu.pUsagePercent),
                 yDomain: 0...1)
        graphRow("GPU", c[1], monitor.history.gpu, String(format: "%.0f%%", s.gpu.usagePercent),
                 yDomain: 0...1)
        graphRow("ANE", c[2], monitor.history.ane, String(format: "%.1f W", s.power.aneWatts),
                 yDomain: 0...max(monitor.anePeakWatts, 0.1))
        graphRow("MED", c[3], monitor.history.media, String(format: "%.1f GB/s", s.bandwidth.mediaGBs),
                 yDomain: 0...max(monitor.mediaPeakGBs, 0.5))
        graphRow("MEM", c[4], monitor.history.memFraction, String(format: "%.0f%%", s.memory.usedPercent),
                 yDomain: 0...1)
        graphRow("MBW", c[5], monitor.history.bandwidth, String(format: "%.0f GB/s", s.bandwidth.totalGBs),
                 yDomain: 0...max(monitor.bandwidthPeakGBs, 1))
    }

    private func graphRow(_ label: String, _ color: Color, _ values: [Double], _ value: String,
                          yDomain: ClosedRange<Double>? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 28, alignment: .leading)
            Sparkline(values: values, color: color, height: 15, yDomain: yDomain)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// Top three processes by CPU — iStat-style at-a-glance "what's busy".
    @ViewBuilder
    private func topProcesses(_ s: SystemSnapshot) -> some View {
        let top = s.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
        Text("TOP PROCESSES")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.faint)
        if top.isEmpty {
            Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
        } else {
            ForEach(Array(top)) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", p.cpuPercent))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.heat(min(1, p.cpuPercent / 100)))
                }
            }
        }
    }
}
