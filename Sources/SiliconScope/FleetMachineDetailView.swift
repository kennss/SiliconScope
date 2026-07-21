//
//  File:      FleetMachineDetailView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Drill-down detail for one fleet machine: the full CPU / memory / GPU(s) / GPU-process /
//             Ollama breakdown behind the compact Fleet row, laid out as labelled cards with usage
//             bars and rolling sparklines (from FleetMonitor's per-machine history). Hardware-adaptive
//             by construction — a Linux box surfaces CUDA util/VRAM/power and its compute processes
//             here, where a Mac agent would surface Apple GPU/ANE in the same slots.
//  Notes:     Reads the live Entry + history from FleetMonitor by machine id, so it keeps updating
//             (and the sparklines keep growing) while open. Sparklines use Swift Charts; they render
//             once there are ≥2 samples.
//
import SwiftUI
import Charts
import SiliconScopeCore

struct FleetMachineDetailView: View {
    let fleet: FleetMonitor
    let machineID: String
    @State private var showPairing = false

    private var entry: FleetMonitor.Entry? { fleet.entries.first { $0.id == machineID } }
    private var pairName: String { entry?.source.label ?? machineID }
    private var history: [FleetMonitor.Sample] { fleet.history[machineID] ?? [] }
    private var hasHistory: Bool { history.count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let entry, let m = entry.metrics {
                    header(m, entry)
                    HStack(alignment: .top, spacing: 12) { cpuCard(m); memoryCard(m) }
                    ForEach(Array(m.gpus.enumerated()), id: \.element.index) { idx, g in
                        gpuCard(g, showChart: idx == 0)
                    }
                    if let o = m.llm?.ollama, o.running { ollamaCard(o) }
                } else if entry?.needsPairing == true {
                    pairingPrompt
                } else if let e = entry?.error {
                    placeholder("exclamationmark.triangle", e, .red)
                } else {
                    placeholder("hourglass", "Connecting…", .secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry?.metrics?.hostname ?? entry?.source.label ?? machineID)
    }

    // MARK: - sections

    private func header(_ m: MachineMetrics, _ entry: FleetMonitor.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            VStack(alignment: .leading, spacing: 1) {
                Text(m.hostname).font(.system(.title3, design: .monospaced).bold())
                Text("\(m.os) · agent \(m.agentVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let u = entry.lastUpdated {
                Text("updated \(u.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func cpuCard(_ m: MachineMetrics) -> some View {
        card("CPU") {
            metricRow("\(m.cpu.cores) cores", pct(m.cpu.usagePercent))
            bar(m.cpu.usagePercent / 100, .blue)
            if hasHistory { spark({ $0.cpu }, .blue, yMax: 100) }
            metricRow("load (1m)", dec2(m.cpu.loadAvg1))
        }
    }

    private func memoryCard(_ m: MachineMetrics) -> some View {
        let frac = m.memory.totalBytes > 0 ? Double(m.memory.usedBytes) / Double(m.memory.totalBytes) : 0
        return card("MEMORY") {
            metricRow("used", "\(gb(m.memory.usedBytes)) / \(gb(m.memory.totalBytes))")
            bar(frac, .purple)
            if hasHistory { spark({ $0.memFrac * 100 }, .purple, yMax: 100) }
            metricRow("free", gb(m.memory.availableBytes))
        }
    }

    private func gpuCard(_ g: FleetGPU, showChart: Bool) -> some View {
        card("GPU · \(g.name)") {
            metricRow("utilization", pct(g.utilizationPercent))
            bar(g.utilizationPercent / 100, .green)
            if showChart && hasHistory { spark({ $0.gpuUtil }, .green, yMax: 100) }
            metricRow("VRAM", "\(gb(g.vramUsedBytes)) / \(gb(g.vramTotalBytes))")
            bar(g.vramFraction, .teal)
            HStack(spacing: 16) {
                labelled("temp", "\(Int(g.temperatureC))°C")
                labelled("power", "\(Int(g.powerDrawW)) / \(Int(g.powerLimitW)) W")
                if g.powerLimitW > 0 { labelled("draw", pct(g.powerDrawW / g.powerLimitW * 100)) }
            }
            if showChart && hasHistory {
                Text("POWER (W)").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                spark({ $0.gpuPowerW }, .orange, yMax: g.powerLimitW > 0 ? g.powerLimitW : 400)
            }
            if !g.processes.isEmpty {
                Divider().padding(.vertical, 2)
                Text("COMPUTE PROCESSES").font(.caption2).foregroundStyle(.secondary)
                ForEach(g.processes, id: \.pid) { p in
                    HStack {
                        Text("\(p.pid)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(p.name).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(gb(p.vramBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
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

    /// Rolling sparkline over the machine's history for one metric.
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
        .frame(height: 34)
    }

    private func placeholder(_ icon: String, _ text: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var pairingPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.slash").font(.largeTitle).foregroundStyle(.orange)
            Text("Pairing required").font(.headline)
            Text("Enter this machine's token (printed by install-agent.sh) to connect securely.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Pair…") { showPairing = true }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(24)
        .sheet(isPresented: $showPairing) {
            PairingSheet(name: pairName) { token in fleet.pair(name: pairName, token: token) }
        }
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private func dec2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}

// MARK: - Pairing sheet

/// Token-entry sheet for pairing a secure agent. The token comes from install-agent.sh's output.
struct PairingSheet: View {
    let name: String
    let onPair: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("Pair \(name)").font(.headline)
            }
            Text("Enter the pairing token printed by the agent installer (install-agent.sh). It encrypts and authenticates this connection.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Pairing token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onPair(trimmed)
        dismiss()
    }
}
