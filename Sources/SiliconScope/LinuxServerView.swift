//
//  File:      LinuxServerView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Detail dashboard for a remote LINUX / NVIDIA server — GPU-centric, unlike the Mac
//             layout. The GPU (util / VRAM / power draw+limit / temp / clock + compute processes)
//             is the headline, with CPU (blended usage + load) and memory below, and Ollama models
//             at the bottom. Deliberately omits the Apple-only concepts (ANE, Media engine, E/P
//             clusters, per-requestor memory bandwidth, fans) that make no sense on a CUDA box.
//  Notes:     Driven by the remote MachineMetrics + FleetMonitor's rolling history (GPU util/power
//             sparklines). This is the "kind == linux" branch of FleetMachineDetailView; Macs use
//             the reused DashboardView instead.
//
import SwiftUI
import Charts
import SiliconScopeCore

struct LinuxServerView: View {
    let fleet: FleetMonitor
    let machineID: String

    private var entry: FleetMonitor.Entry? { fleet.entries.first { $0.id == machineID } }
    private var history: [FleetMonitor.Sample] { fleet.history[machineID] ?? [] }
    private var hasHistory: Bool { history.count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let m = entry?.metrics {
                    header(m)
                    ForEach(Array(m.gpus.enumerated()), id: \.element.index) { idx, g in
                        gpuCard(g, showChart: idx == 0)
                    }
                    HStack(alignment: .top, spacing: 12) { cpuCard(m); memoryCard(m) }
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

    private func gpuCard(_ g: FleetGPU, showChart: Bool) -> some View {
        card("GPU · \(g.name)") {
            metricRow("utilization", pct(g.utilizationPercent))
            bar(g.utilizationPercent / 100, .green)
            if showChart && hasHistory { spark({ $0.gpuUtil }, .green, yMax: 100).frame(height: 44) }

            metricRow("VRAM", "\(gb(g.vramUsedBytes)) / \(gb(g.vramTotalBytes))")
            bar(g.vramFraction, .teal)

            HStack(spacing: 20) {
                labelled("temp", "\(Int(g.temperatureC))°C")
                labelled("power", "\(Int(g.powerDrawW)) / \(Int(g.powerLimitW)) W")
                if let f = g.freqMHz, f > 0 { labelled("clock", "\(Int(f)) MHz") }
                if g.powerLimitW > 0 { labelled("draw", pct(g.powerDrawW / g.powerLimitW * 100)) }
            }
            if showChart && hasHistory {
                Text("POWER (W)").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                spark({ $0.gpuPowerW }, .orange, yMax: g.powerLimitW > 0 ? g.powerLimitW : 400).frame(height: 40)
            }
            if !g.processes.isEmpty {
                Divider().padding(.vertical, 2)
                Text("COMPUTE PROCESSES").font(.caption2).foregroundStyle(.secondary)
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
    }

    private func cpuCard(_ m: MachineMetrics) -> some View {
        card("CPU") {
            metricRow("\(m.cpu.cores) cores", pct(m.cpu.usagePercent))
            bar(m.cpu.usagePercent / 100, .blue)
            if hasHistory { spark({ $0.cpu }, .blue, yMax: 100).frame(height: 36) }
            metricRow("load (1m)", dec2(m.cpu.loadAvg1))
        }
    }

    private func memoryCard(_ m: MachineMetrics) -> some View {
        let frac = m.memory.totalBytes > 0 ? Double(m.memory.usedBytes) / Double(m.memory.totalBytes) : 0
        return card("MEMORY") {
            metricRow("used", "\(gb(m.memory.usedBytes)) / \(gb(m.memory.totalBytes))")
            bar(frac, .purple)
            metricRow("free", gb(m.memory.availableBytes))
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

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
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

    private func spark(_ value: @escaping (FleetMonitor.Sample) -> Double, _ color: Color, yMax: Double) -> some View {
        Chart(history) { s in
            AreaMark(x: .value("t", s.t), y: .value("v", value(s)))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("t", s.t), y: .value("v", value(s)))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(yMax, 1))
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private func dec2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}
