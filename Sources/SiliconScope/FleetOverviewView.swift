//
//  File:      FleetOverviewView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  At-a-glance view of every remote machine at once — an adaptive grid of compact tiles
//             (GPU util + power/temp, VRAM bar, loaded LLM, a mini util sparkline), so a fleet of GPU
//             boxes / Mac servers reads in one screen ("which box is busy / idle / hot right now").
//             Tapping a tile drills into that machine's full detail. This is the sidebar's "Fleet"
//             root, above the individual devices.
//  Notes:     kind-agnostic tiles (GPU 0 + LLM summary work for both NVIDIA and Apple). Pairing /
//             connecting / error states render in-tile. Sparkline uses FleetMonitor's rolling history.
//
import SwiftUI
import Charts
import SiliconScopeCore

struct FleetOverviewView: View {
    let fleet: FleetMonitor
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            if fleet.entries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for agents on your network…")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Install the agent on a machine to see it here.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(fleet.entries) { entry in
                        FleetTile(entry: entry, history: fleet.history[entry.id] ?? [])
                            .onTapGesture { onSelect(entry.id) }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .navigationTitle("Fleet")
    }
}

private struct FleetTile: View {
    let entry: FleetMonitor.Entry
    let history: [FleetMonitor.Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(entry.metrics?.hostname ?? entry.source.label)
                    .font(.system(.callout, design: .monospaced).bold()).lineLimit(1)
                Spacer()
                Image(systemName: entry.needsPairing ? "lock.slash" : "lock.fill")
                    .font(.system(size: 9)).foregroundStyle(entry.needsPairing ? .orange : .secondary)
            }

            if entry.needsPairing {
                spacerText("Pairing required", .orange)
            } else if let m = entry.metrics, let g = m.gpus.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(g.utilizationPercent))%").font(.system(.title2, design: .rounded).bold())
                        .foregroundStyle(utilColor(g.utilizationPercent))
                    Text("GPU").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(g.powerDrawW)) W · \(Int(g.temperatureC))°C")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if history.count >= 2 {
                    Chart(history) { s in
                        AreaMark(x: .value("t", s.t), y: .value("u", s.gpuUtil))
                            .foregroundStyle(Color.green.opacity(0.18))
                        LineMark(x: .value("t", s.t), y: .value("u", s.gpuUtil))
                            .foregroundStyle(.green).interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100)
                    .frame(height: 26)
                } else {
                    Color.clear.frame(height: 26)
                }
                bar(g.vramFraction, .teal)
                Text("VRAM \(gb(g.vramUsedBytes)) / \(gb(g.vramTotalBytes))")
                    .font(.caption2).foregroundStyle(.secondary)
                if let o = m.llm?.ollama, o.running {
                    let loaded = o.loaded.first?.name
                    Text(loaded.map { "● \($0)" } ?? "\(o.models.count) model(s)")
                        .font(.caption2).foregroundStyle(loaded != nil ? .green : .secondary).lineLimit(1)
                }
            } else if let e = entry.error {
                spacerText(e, .red)
            } else {
                spacerText("Connecting…", .secondary)
            }
        }
        .padding(12)
        .frame(height: 158, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
    }

    private func spacerText(_ text: String, _ color: Color) -> some View {
        VStack {
            Spacer()
            Text(text).font(.caption).foregroundStyle(color).lineLimit(2)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func bar(_ fraction: Double, _ color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }

    private var statusColor: Color {
        if entry.needsPairing { return .orange }
        if entry.metrics != nil { return .green }
        if entry.error != nil { return .red }
        return .gray
    }

    private func utilColor(_ pct: Double) -> Color {
        pct >= 80 ? .orange : (pct >= 1 ? .green : .secondary)
    }

    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}
