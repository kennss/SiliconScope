//
//  File:      SiliconScopeRootView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The single-window shell: a NavigationSplitView with a "Devices" sidebar (This Mac +
//             every discovered fleet agent) and a detail pane that shows the selected device's
//             dashboard — the local DashboardContainer for This Mac, FleetMachineDetailView for a
//             remote machine. This replaces the old split of a separate dashboard window and a
//             ⌘⇧F Fleet window: local and remote now live in one place, one click apart.
//  Notes:     `selection` is a Binding owned by the App so the menu-bar glyph can deep-link to a
//             specific machine. Sidebar is collapsible, so viewing only This Mac keeps the full-size
//             dashboard exactly as before. Devices are secure (https) agents; the lock reflects
//             pairing state.
//
import SwiftUI
import SiliconScopeCore

/// Which device the detail pane is showing.
enum DeviceSelection: Hashable {
    case thisMac
    case remote(String)   // fleet machine id
}

struct SiliconScopeRootView: View {
    let monitor: SiliconScopeMonitor
    let fleet: FleetMonitor
    @Binding var selection: DeviceSelection?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    Label("This Mac", systemImage: "laptopcomputer")
                        .tag(DeviceSelection.thisMac)
                    ForEach(fleet.entries) { entry in
                        DeviceSidebarRow(entry: entry) { fleet.unpair(name: $0) }
                            .tag(DeviceSelection.remote(entry.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                if fleet.entries.isEmpty {
                    Label("Searching for agents…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        } detail: {
            switch selection ?? .thisMac {
            case .thisMac:
                DashboardContainer(monitor: monitor)
                    .frame(minWidth: 640, minHeight: 600)
            case .remote(let id):
                FleetMachineDetailView(fleet: fleet, machineID: id)
            }
        }
    }
}

/// One remote machine in the Devices sidebar: status dot, hostname, lock state, and a one-line
/// metric summary. Right-click to forget the pairing.
private struct DeviceSidebarRow: View {
    let entry: FleetMonitor.Entry
    let onUnpair: (String) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.metrics?.hostname ?? entry.source.label)
                        .font(.body).lineLimit(1)
                    Image(systemName: entry.needsPairing ? "lock.slash" : "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(entry.needsPairing ? .orange : .secondary)
                }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .contextMenu {
            if !entry.needsPairing {
                Button("Forget pairing", role: .destructive) { onUnpair(entry.source.label) }
            }
        }
    }

    private var subtitle: String {
        if entry.needsPairing { return "pairing required" }
        guard let m = entry.metrics else { return "connecting…" }
        if let g = m.gpus.first { return "GPU \(Int(g.utilizationPercent))% · \(Int(g.powerDrawW))W" }
        return "CPU \(Int(m.cpu.usagePercent))%"
    }

    private var statusColor: Color {
        if entry.needsPairing { return .orange }
        if entry.metrics != nil { return .green }
        if entry.error != nil { return .red }
        return .gray
    }
}
