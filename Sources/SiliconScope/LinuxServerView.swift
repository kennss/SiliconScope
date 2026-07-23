//
//  File:      LinuxServerView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Detail dashboard for a remote LINUX / NVIDIA server — GPU-centric, distinct from the
//             Mac layout. An identity row (CPU cores / RAM / GPU name / VRAM), then two paired
//             time-series graphs — GPU util + VRAM on one, CPU + RAM on the other — each captioned
//             with the live values as text. Below: GPU compute processes and Ollama models.
//             Deliberately omits Apple-only concepts (ANE / E-P / Media / bandwidth / fans).
//  Notes:     Reuses the app's shared `Sparkline` + `MetricPalette` (line + gradient fill, NOT Swift
//             Charts) so it matches the local GPU/CPU cards — GPU=green, VRAM=sky-cyan, CPU=blue,
//             RAM=amber. Each graph overlays two traces on a shared 0…1 axis (util ÷100; VRAM/RAM
//             fractions as-is). The caption's tinted metric word (GPU/VRAM/CPU/RAM) is the legend.
//             Driven by remote MachineMetrics + FleetMonitor's rolling history.
//
import SwiftUI
import SiliconScopeCore

struct LinuxServerView: View {
    let fleet: FleetMonitor
    let machineID: String

    private var entry: FleetMonitor.Entry? { fleet.entries.first { $0.id == machineID } }
    private var history: [FleetMonitor.Sample] { fleet.history[machineID] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let m = entry?.metrics {
                    header(m)
                    let g = m.gpus.first
                    identityRow(m, g)

                    // Only chart a GPU that exists — a Pi / CPU-only box would otherwise get a
                    // permanently flat "GPU / VRAM" card that says nothing (#33).
                    if g != nil {
                        dualChart(title: "GPU / VRAM", caption: gpuCaption(g),
                                  history.map { $0.gpuUtil / 100 }, MetricPalette.gpuC,
                                  history.map { $0.vramFrac }, MetricPalette.gpuMemC)
                    }
                    dualChart(title: "CPU / RAM", caption: cpuCaption(m),
                              history.map { $0.cpu / 100 }, MetricPalette.cpuC,
                              history.map { $0.memFrac }, MetricPalette.ramC)

                    if let g, !g.processes.isEmpty { computeProcesses(g) }
                    if let o = m.llm?.ollama, o.running { ollamaCard(o) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    // MARK: - sections

    private func header(_ m: MachineMetrics) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
            VStack(alignment: .leading, spacing: 1) {
                Text(m.hostname).font(.system(.title3, design: .monospaced).bold())
                Text("\(m.os) · agent \(m.agentVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let u = entry?.lastUpdated {
                Text("updated \(u.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func identityRow(_ m: MachineMetrics, _ g: FleetGPU?) -> some View {
        card {
            HStack(alignment: .top, spacing: 24) {
                labelled("CPU", "\(m.cpu.cores) cores")
                labelled("RAM", gbInt(m.memory.totalBytes))
                Spacer()
                // Machines without a GPU (Pi, CPU-only server, VM) drop the columns entirely rather
                // than showing "—" twice.
                if let g {
                    labelled("GPU", g.name)
                    labelled("VRAM", gbInt(g.vramTotalBytes))
                }
            }
        }
    }

    // MARK: - captions (the tinted metric word doubles as the graph legend)

    private func gpuCaption(_ g: FleetGPU?) -> Text {
        guard let g else { return Text("no GPU").foregroundStyle(.secondary) }
        let power = g.powerLimitW > 0 ? "\(Int(g.powerDrawW)) / \(Int(g.powerLimitW)) W" : "\(Int(g.powerDrawW)) W"
        return tag("GPU", MetricPalette.gpuC)
            + dim(" \(Int(g.utilizationPercent))% · \(power) · \(Int(g.temperatureC))°C     ")
            + tag("VRAM", MetricPalette.gpuMemC)
            + dim(" \(gb(g.vramUsedBytes)) / \(gb(g.vramTotalBytes))")
    }

    private func cpuCaption(_ m: MachineMetrics) -> Text {
        tag("CPU", MetricPalette.cpuC)
            + dim(" \(Int(m.cpu.usagePercent))% · load \(dec2(m.cpu.loadAvg1))     ")
            + tag("RAM", MetricPalette.ramC)
            + dim(" \(gb(m.memory.usedBytes)) / \(gb(m.memory.totalBytes))")
    }

    private func tag(_ s: String, _ c: Color) -> Text {
        Text(s).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(c)
    }
    private func dim(_ s: String) -> Text {
        Text(s).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
    }

    /// A card with a tinted value caption and two overlaid `Sparkline` traces on a shared 0…1 axis
    /// (values pre-normalized by the caller) — matching the local GPU/CPU cards' look.
    private func dualChart(title: String, caption: Text,
                           _ a: [Double], _ ca: Color, _ b: [Double], _ cb: Color) -> some View {
        card(title) {
            caption.fixedSize(horizontal: false, vertical: true)
            if history.count >= 2 {
                ZStack {
                    Sparkline(values: a, color: ca, yDomain: 0...1, fill: true, grid: true)
                    Sparkline(values: b, color: cb, yDomain: 0...1, fill: true)
                }
                .frame(height: 84)
            } else {
                Color.clear.frame(height: 84)
            }
        }
    }

    private func computeProcesses(_ g: FleetGPU) -> some View {
        card("COMPUTE PROCESSES") {
            ForEach(g.processes, id: \.pid) { p in
                HStack {
                    Text("\(p.pid)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(p.name).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(gb(p.vramBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ollamaCard(_ o: FleetOllama) -> some View {
        card("OLLAMA") {
            let loadedNames = Set(o.loaded.map(\.name))
            ForEach(o.models, id: \.name) { model in
                HStack {
                    Circle().fill(loadedNames.contains(model.name) ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(model.name).font(.system(.caption, design: .monospaced))
                    if loadedNames.contains(model.name) {
                        Text("loaded").font(.caption2).foregroundStyle(.green)
                    }
                    Spacer()
                    Text(gb(model.sizeBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - building blocks

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1)
        }
    }

    private func dec2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private func gbInt(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB" }
}
