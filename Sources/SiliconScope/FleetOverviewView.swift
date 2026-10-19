//
//  File:      FleetOverviewView.swift
//  Created:   2026-07-22
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  At-a-glance view of every machine at once — an adaptive grid of compact tiles. THIS
//             MAC is always the first tile (a laptop glyph, taps through to its full dashboard);
//             discovered remote agents follow. Each tile has the same paired-graph form as the local
//             dashboard: a GPU+VRAM mini graph and a CPU+RAM mini graph, each overlaying two
//             `Sparkline` traces (line + gradient fill), with the caption's metric word tinted its
//             line color so it doubles as the legend. So a fleet of GPU boxes / Mac servers reads in
//             one screen ("which box is busy / idle / hot right now"). With no remote machine yet,
//             the page carries the install command (copyable) and a link to docs/fleet.md. A tile
//             of a box running Docker ends with its container count, and how many were restarted.
//             A box with two GPUs charts each; with more, each card gets one caption line (four at
//             most, then a count), as their charts would no longer fit the tile.
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.section)], spacing: Space.section) {
                if let local = fleet.localMetrics {
                    FleetTile(hostname: local.hostname, metrics: local, history: fleet.localHistory,
                              needsPairing: false, error: nil, isLocal: true, onTap: onSelectLocal)
                }
                ForEach(fleet.entries) { entry in
                    FleetTile(hostname: entry.displayName,
                              metrics: entry.metrics, history: fleet.history[entry.id] ?? [],
                              needsPairing: entry.needsPairing, error: entry.error,
                              isLocal: false, onTap: { onSelect(entry.id) })
                }
            }
            .padding(Space.page)

            if fleet.entries.isEmpty { emptyFleet }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .navigationTitle("Fleet")
    }

    /// The one screen everyone who opens Fleet sees before adding anything, so it carries the whole
    /// way in: the command, what to do with what it prints, and the manual for every other case.
    /// Few people read a README; this is where the feature is found.
    private var emptyFleet: some View {
        VStack(spacing: Space.row) {
            HStack(spacing: Space.row) {
                ProgressView().controlSize(.small)
                Text("Searching for other agents on your network…")
                    .font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            Text("To add a machine, run this on it (Linux or macOS):")
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
            HStack(spacing: Space.row) {
                Text(Self.installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.installCommand, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy command")
            }
            .padding(.horizontal, Space.section).padding(.vertical, Space.row)
            .background(RoundedRectangle(cornerRadius: Radius.panel).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: 1))
            Text("It prints an sscope://pair… link. Paste it into Add machine… at the bottom of the sidebar.")
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
            Text("Another Mac you use: turn on Settings → Share this Mac to Fleet there.")
                .font(Theme.font(.caption)).foregroundStyle(.tertiary)
            Link("Fleet manual: GPU boxes, cloud servers over Tailscale, troubleshooting",
                 destination: Self.manualURL)
                .font(Theme.font(.caption))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.horizontal, Space.page).padding(.bottom, Space.page)
    }

    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh"
    static let manualURL = URL(string: "https://github.com/kennss/SiliconScope/blob/main/docs/fleet.md")!
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
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(spacing: Space.row) {
                Circle().fill(statusColor).frame(width: Layout.Dot.status, height: Layout.Dot.status)
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
                if m.gpus.count <= 2 {
                    ForEach(m.gpus) { g in
                        gpuCaption(g, numbered: m.gpus.count > 1, apple: m.apple)
                        miniChart(history.gpuUtil(g), MetricPalette.gpuC,
                                  history.vramFrac(g), MetricPalette.gpuMemC)
                    }
                } else {
                    ForEach(m.gpus.prefix(Self.gpuLines)) { g in gpuCaption(g, numbered: true, apple: m.apple) }
                    if m.gpus.count > Self.gpuLines {
                        Text("+\(m.gpus.count - Self.gpuLines) more GPUs")
                            .font(Theme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
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
                        .font(Theme.font(.caption)).foregroundStyle(loaded != nil ? .green : .secondary).lineLimit(1)
                }
                // On a box that runs services, the containers are its state: how many, and whether
                // Docker has had to bring any back. Amber only for that — it exited on its own.
                if let cs = m.containers, !cs.isEmpty {
                    let restarted = cs.filter(\.hasRestarted).count
                    HStack(spacing: 0) {
                        Text("\(cs.count) container\(cs.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                        if restarted > 0 {
                            Text(" · \(restarted) restarted").foregroundStyle(Palette.State.warn.color)
                        }
                    }
                    .font(Theme.font(.caption)).lineLimit(1)
                }
                // The decode rate is what "how is this box performing" actually means for an LLM
                // host, so it belongs on the tile rather than one level down. Dimmed once it stops
                // describing the present — the number stays readable, its authority does not.
                if let r = m.llm?.rate {
                    Text(String(format: "%.0f tok/s · %@", r.tokensPerSec,
                                LinuxServerView.ageLabel(r.age)))
                        .font(Theme.font(.caption))
                        .foregroundStyle(r.age < 120 ? Theme.text : Theme.faint)
                        .lineLimit(1)
                }
            } else if let e = error {
                spacerText(e, .red)
            } else {
                spacerText("Connecting…", .secondary)
            }
        }
        .padding(Space.section)
        .frame(height: tileHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// All tiles share one height; the charts flex to fill, so a 2-chart (Linux) and a 3-chart
    /// (Apple, incl. ANE/Bandwidth) tile are the same size with no dead space.
    private let tileHeight: CGFloat = 246
    /// GPU caption lines a tile has room for on a box with more than two cards.
    private static let gpuLines = 4

    @ViewBuilder private var cornerGlyph: some View {
        if isLocal {
            Image(systemName: "laptopcomputer").font(.system(size: Icon.small)).foregroundStyle(.secondary)
        } else {
            Image(systemName: needsPairing ? "lock.slash" : "lock.fill")
                .font(.system(size: Icon.small)).foregroundStyle(needsPairing ? .orange : .secondary)
        }
    }

    // MARK: - captions (the tinted metric word doubles as the chart legend)

    private func gpuCaption(_ g: FleetGPU, numbered: Bool, apple: FleetApple?) -> some View {
        // Watts and °C the machine can't vouch for are left out, not printed as 0 (FleetReadout).
        let parts = ["\(Int(g.utilizationPercent))%", FleetReadout.gpuWatts(g, apple: apple),
                     FleetReadout.gpuTemperature(g, apple: apple)].compactMap { $0 }
        return (tag(numbered ? "GPU\(g.index)" : "GPU", MetricPalette.gpuC)
         + dim(" " + parts.joined(separator: " · ") + " · ")
         + tag("VRAM", MetricPalette.gpuMemC)
         + dim(" \(gb(g.vramUsedBytes))/\(gb(g.vramTotalBytes))"))
            .font(Theme.font(.caption)).lineLimit(1)
    }

    private func cpuCaption(_ m: MachineMetrics) -> some View {
        (tag("CPU", MetricPalette.cpuC)
         + dim(" \(Int(m.cpu.usagePercent))% · \(m.cpu.cores) cores · ")
         + tag("RAM", MetricPalette.ramC)
         + dim(" \(gb(m.memory.usedBytes))/\(gb(m.memory.totalBytes))"))
            .font(Theme.font(.caption)).lineLimit(1)
    }

    private func aneCaption(_ a: FleetApple) -> some View {
        (tag("ANE", MetricPalette.aneC)
         + dim(" " + (a.aneActiveFraction.map { String(format: "%.0f%%", $0 * 100) }
                      ?? a.powerSample.text(a.aneWatts, format: "%.1fW")) + " · ")
         // "Mem BW", not "BW": beside the ANE figure a bare "BW" read as the ANE's own traffic,
         // when it is the whole chip's memory bandwidth (a GPU LLM pushes it to ~270 GB/s while
         // the ANE sits at 0%).
         + tag("Mem BW", MetricPalette.mediaC)
         + dim(String(format: " %.0f GB/s", a.bandwidth.totalGBs)))
            .font(Theme.font(.caption)).lineLimit(1)
    }

    private func tag(_ s: String, _ c: Color) -> Text { Text(s).foregroundStyle(c).bold() }
    private func dim(_ s: String) -> Text { Text(s).foregroundStyle(.secondary) }

    /// Two overlaid `Sparkline` traces on a shared 0…1 axis (values pre-normalized by the caller).
    /// Flexes to fill the tile's spare height so 2-chart and 3-chart tiles stay the same size.
    private func miniChart(_ a: [Double], _ ca: Color, _ b: [Double], _ cb: Color) -> some View {
        Group {
            if history.count >= 2 {
                Sparkline([Trace(a, ca), Trace(b, cb)], role: .trend)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: .infinity)
    }

    private func spacerText(_ text: String, _ color: Color) -> some View {
        VStack {
            Spacer()
            Text(text).font(Theme.font(.caption)).foregroundStyle(color).lineLimit(2)
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
