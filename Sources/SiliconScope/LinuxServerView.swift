//
//  File:      LinuxServerView.swift
//  Created:   2026-07-22
//  Updated:   2026-08-10
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
            VStack(alignment: .leading, spacing: Space.section) {
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
                    if let rate = m.llm?.rate { tokenRateCard(rate) }
                    if let o = m.llm?.ollama, o.running { ollamaCard(o) }
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    // MARK: - sections

    private func header(_ m: MachineMetrics) -> some View {
        HStack(spacing: Space.card) {
            Image(systemName: "server.rack")
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(m.hostname).font(.system(.title3, design: .monospaced).bold())
                Text("\(m.os) · agent \(m.agentVersion)").font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if let u = entry?.lastUpdated {
                Text("updated \(u.formatted(date: .omitted, time: .standard))")
                    .font(Theme.font(.caption)).foregroundStyle(.tertiary)
            }
        }
    }

    private func identityRow(_ m: MachineMetrics, _ g: FleetGPU?) -> some View {
        card {
            HStack(alignment: .top, spacing: Space.page) {
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
                // `.trend` fills its container, so a fixed frame gives the card a fixed-height
                // chart while keeping the trend role's shared axis and gridlines.
                Sparkline([Trace(a, ca), Trace(b, cb)], role: .trend)
                    .frame(height: Layout.Meter.fleetChart)
            } else {
                Color.clear.frame(height: Layout.Meter.fleetChart)
            }
        }
    }

    private func computeProcesses(_ g: FleetGPU) -> some View {
        card("COMPUTE PROCESSES") {
            ForEach(g.processes, id: \.pid) { p in
                HStack {
                    Text("\(p.pid)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: Layout.Column.linuxLabel, alignment: .leading)
                    Text(p.name).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(gb(p.vramBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The runtime's own decode rate for work it has already done.
    ///
    /// The age is shown beside the number rather than under it, because the two are one fact: this
    /// machine reached 28 tok/s — *when*. Without the age a rate from an hour ago reads as live,
    /// which is the same mistake as asserting a state with no measurement behind it.
    private func tokenRateCard(_ r: FleetTokenRate) -> some View {
        card("GENERATION") {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(String(format: "%.1f", r.tokensPerSec))
                    .font(Theme.font(.emphasis, .strong))
                Text("tok/s").font(Theme.font(.caption)).foregroundStyle(.secondary)
                Spacer()
                Text(Self.ageLabel(r.age)).font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.row) {
                Text(r.sourceLabel).font(Theme.font(.caption)).foregroundStyle(.secondary)
                if let model = r.model {
                    Text(model).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let ttft = r.ttftSec, ttft > 0 {
                    Text(String(format: "first token %.2fs", ttft))
                        .font(Theme.font(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "just now" / "3 min ago" / "2 h ago" — coarse on purpose. The point is whether the number
    /// still describes what the machine is doing, not the exact second it was taken.
    static func ageLabel(_ age: TimeInterval) -> String {
        switch age {
        case ..<45:     return "just now"
        case ..<3600:   return "\(Int(age / 60)) min ago"
        case ..<86_400: return "\(Int(age / 3600)) h ago"
        default:        return "\(Int(age / 86_400)) d ago"
        }
    }

    private func ollamaCard(_ o: FleetOllama) -> some View {
        card("OLLAMA") {
            let loadedNames = Set(o.loaded.map(\.name))
            ForEach(o.models, id: \.name) { model in
                HStack {
                    Circle().fill(loadedNames.contains(model.name) ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: Layout.Dot.linux, height: Layout.Dot.linux)
                    Text(model.name).font(.system(.caption, design: .monospaced))
                    if loadedNames.contains(model.name) {
                        Text("loaded").font(Theme.font(.caption)).foregroundStyle(.green)
                    }
                    Spacer()
                    Text(gb(model.sizeBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - building blocks

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            if let title { Text(title.uppercased()).font(Theme.font(.sectionMinor)).tracking(Theme.tracking(.sectionMinor)).foregroundStyle(.secondary) }
            content()
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.panel).fill(.quaternary.opacity(0.35)))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(label).font(Theme.font(.caption)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1)
        }
    }

    private func dec2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private func gbInt(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB" }
}
