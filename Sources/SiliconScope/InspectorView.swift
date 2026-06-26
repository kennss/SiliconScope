//
//  File:      InspectorView.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Single-process Inspector sheet: every per-process metric for the focused pid —
//             CPU (+ P/E split), Compute (IPC / instructions / cycles), Energy (power + wakeups),
//             Memory footprint, Neural-Engine memory (the one genuine per-process ANE signal),
//             and Disk — each with a live sparkline. Plus a clearly-labeled system-wide
//             Accelerators card (GPU/ANE-power/Media/bandwidth are NOT attributable per process).
//  Notes:     Reads monitor.focusedDetail/focusedHistory/focusEnded (@Observable → live updates).
//             Built from the shared Card/KV/Sparkline atoms so it reads as part of the suite.
//             Unavailable values render "—" (first sample, not-own, or chip doesn't expose them).
//
import SwiftUI
import SiliconScopeCore

struct InspectorView: View {
    let monitor: SiliconScopeMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let d = monitor.focusedDetail
        let h = monitor.focusedHistory
        VStack(spacing: 0) {
            header(d)
            ScrollView {
                VStack(spacing: 8) {
                    if monitor.focusEnded {
                        banner("Process exited", "The focused process is no longer running — last values shown.")
                    }
                    if let d, !d.isOwn {
                        banner("Limited", "Not your process — per-process metrics need a process you own.")
                    }
                    if let d, d.isOwn {
                        metricCards(d, h)
                    } else if d == nil && !monitor.focusEnded {
                        Text("Sampling…")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.dim).padding(.vertical, 20)
                    }
                    acceleratorsCard()
                }
                .padding(10)
            }
        }
        .frame(width: 460, height: 640)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private func header(_ d: ProcessDetail?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d?.name ?? "Process \(monitor.focusedPID.map { "\($0)" } ?? "")")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                if let d {
                    HStack(spacing: 6) {
                        Text("pid \(d.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        if d.uptime > 0 {
                            Text("· up \(uptime(d.uptime))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                        if d.usesANE {
                            Text("· ANE").font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                        }
                    }
                    if !d.path.isEmpty {
                        Text(d.path).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    @ViewBuilder private func metricCards(_ d: ProcessDetail, _ h: ProcessDetailHistory) -> some View {
        Card(title: "CPU") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "CPU", value: pct(d.cpuPercent))
                KV(key: "P-core / E-core", value: "\(pct(d.cpuPPercent)) / \(pct(eCore(d)))")
                KV(key: "Threads", value: "\(d.threads)")
                Sparkline(values: h.cpu, color: Theme.accent, height: 26)
            }
        }
        Card(title: "Compute") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "IPC", value: d.ipc.map { String(format: "%.2f", $0) } ?? "—",
                   valueColor: Theme.accent)
                KV(key: "Instructions/s", value: si(d.instructionsPerSec))
                KV(key: "Cycles/s", value: si(d.cyclesPerSec))
                Sparkline(values: h.ipc, color: Color(red: 0.74, green: 0.53, blue: 0.99), height: 26)
            }
        }
        Card(title: "Energy") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "Power", value: d.powerWatts.map { String(format: "%.2f W", $0) } ?? "—",
                   valueColor: Theme.accent)
                KV(key: "Wakeups/s", value: d.wakeupsPerSec.map { String(format: "%.0f", $0) } ?? "—")
                Sparkline(values: h.power, color: Color(red: 0.98, green: 0.62, blue: 0.30), height: 26)
            }
        }
        Card(title: "Memory") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "Footprint", value: bytes(d.memoryBytes))
                KV(key: "Resident", value: bytes(d.residentBytes))
                Sparkline(values: h.memory, color: Color(red: 0.93, green: 0.46, blue: 0.66), height: 26)
            }
        }
        Card(title: "Neural Engine (ANE)") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "ANE memory", value: d.aneMemoryBytes > 0 ? bytes(d.aneMemoryBytes) : "—",
                   valueColor: d.usesANE ? Theme.accent : Theme.dim)
                KV(key: "Peak", value: d.aneMemoryPeakBytes > 0 ? bytes(d.aneMemoryPeakBytes) : "—")
                Text(d.usesANE ? "This process is using the Neural Engine."
                               : "Not using the Neural Engine.")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
                if d.aneMemoryBytes > 0 { Sparkline(values: h.aneMemory, color: Theme.accent, height: 26) }
            }
        }
        Card(title: "Disk") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "Read", value: bps(d.diskReadBytesPerSec))
                KV(key: "Write", value: bps(d.diskWriteBytesPerSec))
                KV(key: "Open files", value: "\(d.openFiles)")
            }
        }
    }

    private func acceleratorsCard() -> some View {
        let s = monitor.snapshot
        return Card(title: "Accelerators — system-wide") {
            VStack(alignment: .leading, spacing: 4) {
                KV(key: "GPU", value: String(format: "%.0f%%", s.gpu.usage * 100))
                KV(key: "ANE power", value: String(format: "%.1f W", s.power.aneWatts))
                KV(key: "Media engine", value: String(format: "%.1f GB/s", s.bandwidth.mediaGBs))
                KV(key: "Memory bandwidth", value: String(format: "%.0f GB/s", s.bandwidth.totalGBs))
                Text("System-wide — macOS doesn't attribute these to a single process (sudoless).")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
            }
        }
    }

    private func banner(_ title: String, _ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(msg).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - formatters
    private func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func eCore(_ d: ProcessDetail) -> Double? {
        guard let c = d.cpuPercent, let p = d.cpuPPercent else { return nil }
        return max(0, c - p)
    }
    private func bytes(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.2f GB", g) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
    private func si(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return String(format: "%.0f", v)
    }
    private func bps(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB/s", v / 1e3) }
        return String(format: "%.0f B/s", v)
    }
    private func uptime(_ s: TimeInterval) -> String {
        let t = Int(s)
        if t >= 3600 { return "\(t/3600)h \((t%3600)/60)m" }
        if t >= 60 { return "\(t/60)m" }
        return "\(t)s"
    }
}
