//
//  File:      FleetOverviewView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  At-a-glance view of every machine at once — an adaptive grid of compact tiles. THIS
//             MAC is always the first tile (a laptop glyph, taps through to its full dashboard);
//             discovered remote agents follow. Each tile has the same paired-graph form as the local
//             dashboard: a GPU+VRAM mini graph and a CPU+RAM mini graph, each overlaying two
//             `Sparkline` traces (line + gradient fill), with the caption's metric word tinted its
//             line color so it doubles as the legend. So a fleet of GPU boxes / Mac servers reads in
//             one screen ("which box is busy / idle / hot right now").
//  Notes:     Uses the shared `Sparkline` + `MetricPalette` (NOT Swift Charts) to match the local
//             GPU/CPU cards exactly — GPU=green, VRAM=sky-cyan, CPU=blue, RAM=amber. All four series
//             are normalized to 0…1 (util ÷100; VRAM/RAM fractions as-is) to share one axis. FleetTile
//             is kind-agnostic (GPU 0 + LLM summary work for Apple + NVIDIA) and source-agnostic
//             (local Mac = FleetMonitor.localMetrics/localHistory; remote = entry + fleet.history).
//
import SwiftUI
import SiliconScopeCore

struct FleetOverviewView: View {
    let fleet: FleetMonitor
    let onSelect: (String) -> Void      // tapped a remote machine → open its detail
    let onSelectLocal: () -> Void       // tapped This Mac → open the local dashboard

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                if let local = fleet.localMetrics {
                    FleetTile(hostname: local.hostname, metrics: local, history: fleet.localHistory,
                              needsPairing: false, error: nil, isLocal: true, onTap: onSelectLocal)
                }
                ForEach(fleet.entries) { entry in
                    FleetTile(hostname: entry.metrics?.hostname ?? entry.source.label,
                              metrics: entry.metrics, history: fleet.history[entry.id] ?? [],
                              needsPairing: entry.needsPairing, error: entry.error,
                              isLocal: false, onTap: { onSelect(entry.id) })
                }
            }
            .padding(16)

            if fleet.entries.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching for other agents on your network…")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Install the agent on a machine to see it here.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .navigationTitle("Fleet")
    }
}

private struct FleetTile: View {
    let hostname: String
    let metrics: MachineMetrics?
    let history: [FleetMonitor.Sample]
    let needsPairing: Bool
    let error: String?
    let isLocal: Bool                    // This Mac: a laptop glyph instead of a pairing lock
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(hostname)
                    .font(.system(.callout, design: .monospaced).bold()).lineLimit(1)
                Spacer()
                cornerGlyph
            }

            if needsPairing {
                spacerText("Pairing required", .orange)
            } else if let m = metrics {
                // A GPU is optional — a Raspberry Pi, CPU-only server or VM has none, and requiring
                // one here left such a machine stuck on "Connecting…" even though it was reporting
                // fine (#33). CPU/RAM is what every machine has, so that's the row that always draws.
                if let g = m.gpus.first {
                    gpuCaption(g)
                    miniChart(history.map { $0.gpuUtil / 100 }, MetricPalette.gpuC,
                              history.map { $0.vramFrac }, MetricPalette.gpuMemC)
                }
                cpuCaption(m)
                miniChart(history.map { $0.cpu / 100 }, MetricPalette.cpuC,
                          history.map { $0.memFrac }, MetricPalette.ramC)
                if let a = m.apple {   // Apple-only signature metrics: ANE + memory bandwidth
                    aneCaption(a)
                    miniChart(history.map { $0.aneFrac }, MetricPalette.aneC,
                              history.map { $0.bwFrac }, MetricPalette.mediaC)
                }
                if let o = m.llm?.ollama, o.running {
                    let loaded = o.loaded.first?.name
                    Text(loaded.map { "● \($0)" } ?? "\(o.models.count) model(s)")
                        .font(.caption2).foregroundStyle(loaded != nil ? .green : .secondary).lineLimit(1)
                }
            } else if let e = error {
                spacerText(e, .red)
            } else {
                spacerText("Connecting…", .secondary)
            }
        }
        .padding(12)
        .frame(height: tileHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// All tiles share one height; the charts flex to fill, so a 2-chart (Linux) and a 3-chart
    /// (Apple, incl. ANE/Bandwidth) tile are the same size with no dead space.
    private let tileHeight: CGFloat = 246

    @ViewBuilder private var cornerGlyph: some View {
        if isLocal {
            Image(systemName: "laptopcomputer").font(.system(size: 9)).foregroundStyle(.secondary)
        } else {
            Image(systemName: needsPairing ? "lock.slash" : "lock.fill")
                .font(.system(size: 9)).foregroundStyle(needsPairing ? .orange : .secondary)
        }
    }

    // MARK: - captions (the tinted metric word doubles as the chart legend)

    private func gpuCaption(_ g: FleetGPU) -> some View {
        (tag("GPU", MetricPalette.gpuC)
         + dim(" \(Int(g.utilizationPercent))% · \(Int(g.powerDrawW))W · \(Int(g.temperatureC))°C · ")
         + tag("VRAM", MetricPalette.gpuMemC)
         + dim(" \(gb(g.vramUsedBytes))/\(gb(g.vramTotalBytes))"))
            .font(.caption2).lineLimit(1)
    }

    private func cpuCaption(_ m: MachineMetrics) -> some View {
        (tag("CPU", MetricPalette.cpuC)
         + dim(" \(Int(m.cpu.usagePercent))% · \(m.cpu.cores) cores · ")
         + tag("RAM", MetricPalette.ramC)
         + dim(" \(gb(m.memory.usedBytes))/\(gb(m.memory.totalBytes))"))
            .font(.caption2).lineLimit(1)
    }

    private func aneCaption(_ a: FleetApple) -> some View {
        (tag("ANE", MetricPalette.aneC)
         + dim(String(format: " %.1fW · ", a.aneWatts))
         + tag("BW", MetricPalette.mediaC)
         + dim(String(format: " %.0f GB/s", a.bandwidth.totalGBs)))
            .font(.caption2).lineLimit(1)
    }

    private func tag(_ s: String, _ c: Color) -> Text { Text(s).foregroundStyle(c).bold() }
    private func dim(_ s: String) -> Text { Text(s).foregroundStyle(.secondary) }

    /// Two overlaid `Sparkline` traces on a shared 0…1 axis (values pre-normalized by the caller).
    /// Flexes to fill the tile's spare height so 2-chart and 3-chart tiles stay the same size.
    private func miniChart(_ a: [Double], _ ca: Color, _ b: [Double], _ cb: Color) -> some View {
        Group {
            if history.count >= 2 {
                ZStack {
                    Sparkline(values: a, color: ca, yDomain: 0...1, fill: true, grid: true)
                    Sparkline(values: b, color: cb, yDomain: 0...1, fill: true)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: .infinity)
    }

    private func spacerText(_ text: String, _ color: Color) -> some View {
        VStack {
            Spacer()
            Text(text).font(.caption).foregroundStyle(color).lineLimit(2)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        if needsPairing { return .orange }
        if metrics != nil { return .green }
        if error != nil { return .red }
        return .gray
    }

    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}
