//
//  File:      MenuBarView.swift
//  Created:   2026-06-08
//  Updated:   2026-11-20
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
    // Each of these is its own SwiftUI root (an NSHostingController popover, a sibling
    // Scene, or the window), so it must observe the scale keys itself — an environment
    // value injected upstream never arrives here. Read only to invalidate on change; the
    // tokens themselves read the store (see UIScale).
    @AppStorage(UIScale.zoomKey) private var uiZoom = 1.0
    @AppStorage(UIScale.densityKey) private var uiDensity = Density.standard.rawValue
    let monitor: SiliconScopeMonitor
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("compactGPUMode") private var compactGPU = false

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: Space.hair) {
            if compactGPU {
                compactGPURow(snapshot)
            } else {
                fullReadout(snapshot)
            }

            Divider()
                .padding(.bottom, Space.hair)
            // One full-width primary action, then two equal-width secondary buttons — all
            // share PopoverButtonStyle so they match the cards (panel fill, hairline border,
            // mono label) at a uniform height. "Check for Updates…" lives in Settings.
            VStack(spacing: Space.row) {
                Button {
                    openMainDashboard()
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                }
                .buttonStyle(PopoverButtonStyle(prominent: true))

                HStack(spacing: Space.row) {
                    Button("Settings") { openAppSettings() }
                        .buttonStyle(PopoverButtonStyle())
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(PopoverButtonStyle())
                }
            }
        }
        .padding(Space.section)
        .frame(width: compactGPU ? Layout.Surface.combinedWidthCompactGPU : Layout.Surface.combinedWidth)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    /// Single-line GPU-focused readout: GPU% / GPU W / GPU bandwidth / die °C.
    @ViewBuilder
    private func compactGPURow(_ s: SystemSnapshot) -> some View {
        HStack(spacing: Space.card) {
            Text("GPU")
                .font(Theme.font(.body, .strong))
                .foregroundStyle(Theme.accent)
            compactValue(String(format: "%.0f%%", s.gpu.usagePercent), color: Theme.heat(s.gpu.usage))
            compactSeparator
            compactValue(s.power.gpuText())
            compactSeparator
            compactValue(s.bandwidth.laneText(s.bandwidth.gpuGBs))
            compactSeparator
            compactValue(formatTemperature(s.temperature.cpuCelsius, fahrenheit: fahrenheit),
                         color: monitor.gpuThrottling ? Theme.heat(1) : Theme.text)
            if monitor.gpuThrottling {
                Image(systemName: "flame.fill")
                    .font(.system(size: Icon.large))
                    .foregroundStyle(Theme.heat(1))
                    .help("GPU thermal throttling")
            }
        }
    }

    private func compactValue(_ text: String, color: Color = Theme.text) -> some View {
        Text(text)
            .font(Theme.font(.emphasis))
            .foregroundStyle(color)
    }

    private var compactSeparator: some View {
        Text("·").font(Theme.font(.emphasis)).foregroundStyle(Theme.faint)
    }

    /// "Workload" label, qualified with "(est.)" when the bandwidth-bound verdict rests on an
    /// estimated reading (BandwidthSampler's PMP-histogram fallback — see BandwidthSample.isEstimated)
    /// rather than a real per-requestor byte-delta measurement, so the label doesn't overstate
    /// precision it doesn't have.
    private func workloadLabel(_ snapshot: SystemSnapshot) -> String {
        let label = monitor.bottleneck.label
        guard monitor.bottleneck == .bandwidthBound, snapshot.bandwidth.isEstimated else { return label }
        return label + " (est.)"
    }

    /// The standard multi-line readout (E/P, memory, GPU, ANE, bandwidth, power, temps).
    @ViewBuilder
    private func fullReadout(_ snapshot: SystemSnapshot) -> some View {
        Text("SiliconScope")
            .font(Theme.font(.headline, .strong))
            .foregroundStyle(Theme.accent)

        KV(key: "Workload", value: workloadLabel(snapshot), valueColor: monitor.bottleneck.color)

        Divider()
        KV(key: "GPU", value: String(format: "%.0f%% · ", snapshot.gpu.usagePercent) + snapshot.power.gpuText())
        KV(key: "ANE", value: snapshot.aneText())
        KV(key: "Media", value: snapshot.bandwidth.mediaText)
        KV(key: "Mem BW", value: snapshot.bandwidth.totalText)
        // The dashboard header's figure, not the bare SoC total: on macOS 27 the SoC counters
        // can go minutes without updating (#65), and "SoC power —" said nothing about why. The
        // header shows the whole Mac's SMC-measured draw then, labelled as such, or says the
        // reading is pending.
        let power = snapshot.power.headerFigure
        KV(key: power.label == "system" ? "System power" : "SoC power",
           value: power.label == nil || power.label == "system" ? power.value : "\(power.value) · \(power.label!)")
            .help(power.help ?? "")
        KV(key: "CPU temp", value: formatTemperature(snapshot.temperature.cpuCelsius, fahrenheit: fahrenheit))
        if snapshot.temperature.hasBattery {
            KV(key: "Battery", value: formatTemperature(snapshot.temperature.batteryCelsius, fahrenheit: fahrenheit))
        }

        Divider()
        KV(key: "AI runtime", value: snapshot.aiRuntimeLabel)
        // The same wording as the dashboard's AI Runtime card (ModelBudgetText.swift).
        KV(key: "Model budget",
           value: snapshot.memoryBudget.summary(
               residentModel: MemoryBudget.residentModelName(api: snapshot.runtimeAPI, runtime: snapshot.aiRuntime)))
            .help(snapshot.memoryBudget.basisHelp)

        Divider()
        metricGraphs(snapshot)

        Divider()
        topProcesses(snapshot)
    }

    /// Six trend graphs — same metrics, colors AND normalization as the menu-bar glyph.
    /// Each is plotted on a FIXED Y domain matching its bar (utilization 0...1, ANE/Media
    /// vs their tracked peaks, Mem BW vs its observed peak), so a small or flat signal reads
    /// small. Auto-scaling would stretch any series to fill the row — looks exaggerated.
    /// Series that move tick to tick are bars, one per sample; memory in use is a slow level and
    /// stays a line (Theme.swift, Sparkline).
    @ViewBuilder
    private func metricGraphs(_ s: SystemSnapshot) -> some View {
        let c = MenuBarIcon.barColors.map(Color.init(nsColor:))
        Text("TRENDS")
            .font(Theme.font(.sectionMinor))
            .foregroundStyle(Theme.faint)
        graphRow("CPU", c[0], String(format: "%.0f%%", s.cpu.pUsagePercent)) {
            WellChart(values: monitor.history.pCPU, color: c[0], ceiling: 1)
        }
        graphRow("GPU", c[1], String(format: "%.0f%%", s.gpu.usagePercent)) {
            WellChart(values: monitor.history.gpu, color: c[1], ceiling: 1)
        }
        // Already 0…1 (residency, or watts scaled to their peak) — a further ceiling would scale it twice.
        graphRow("ANE", c[2], s.aneText()) {
            WellChart(values: monitor.history.aneSeries(measured: s.ane != nil, peakWatts: monitor.anePeakWatts),
                      color: c[2], ceiling: 1)
        }
        graphRow("MED", c[3], s.bandwidth.mediaText) {
            WellChart(values: monitor.history.media, color: c[3], ceiling: max(monitor.mediaPeakGBs, 0.5))
        }
        graphRow("MEM", c[4], String(format: "%.0f%%", s.memory.usedPercent)) {
            Sparkline(monitor.history.memFraction, color: c[4],
                      role: .inline(height: Layout.Meter.sparklineListRow, axis: .fraction))
        }
        graphRow("MBW", c[5], s.bandwidth.totalText) {
            WellChart(values: monitor.history.bandwidth, color: c[5], ceiling: max(monitor.bandwidthPeakGBs, 1))
        }
    }

    private func graphRow<Chart: View>(_ label: String, _ color: Color, _ value: String,
                                       @ViewBuilder chart: () -> Chart) -> some View {
        HStack(spacing: Space.row) {
            Text(label)
                .font(Theme.font(.caption, .strong))
                .foregroundStyle(color)
                .frame(width: Layout.Column.trendLabel, alignment: .leading)
            chart().frame(height: Layout.Meter.sparklineListRow)
            Text(value)
                .font(Theme.font(.detail, .strong))
                .foregroundStyle(Theme.dim)
                .frame(width: Layout.Column.trendValue, alignment: .trailing)
        }
    }

    /// The three busiest apps — the same folded list as the CPU dropdown, so Chrome's helpers are
    /// one row here too and names are cut the same way.
    @ViewBuilder
    private func topProcesses(_ s: SystemSnapshot) -> some View {
        Text("TOP BY CPU")
            .font(Theme.font(.sectionMinor))
            .foregroundStyle(Theme.faint)
        TopAppsList(processes: s.processes, measure: .cpu, limit: 3)
    }
}
