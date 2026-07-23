//
//  File:      SiliconScopeRootView.swift
//  Created:   2026-07-22
//  Updated:   2026-07-23
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The single-window shell: a NavigationSplitView with a "Devices" sidebar (This Mac +
//             every discovered fleet agent) and a detail pane that shows the selected device's
//             dashboard — the local DashboardContainer for This Mac, FleetMachineDetailView for a
//             remote machine. This replaces the old split of a separate dashboard window and a
//             ⌘⇧F Fleet window: local and remote now live in one place, one click apart.
//  Notes:     `selection` is a Binding because the App owns the state, so the chosen device survives
//             closing and reopening the window. Sidebar is collapsible, so viewing only This Mac
//             keeps the full-size dashboard exactly as before. Devices are secure (https) agents; the lock reflects
//             pairing state. "Add machine…" registers an off-LAN endpoint (Tailscale / VPN / cloud)
//             that mDNS can't auto-discover; manual rows can be removed from their context menu.
//
import SwiftUI
import SiliconScopeCore

/// Which device the detail pane is showing.
enum DeviceSelection: Hashable {
    case fleet               // at-a-glance overview of all remote machines
    case thisMac
    case remote(String)      // fleet machine id
}

struct SiliconScopeRootView: View {
    let monitor: SiliconScopeMonitor
    let fleet: FleetMonitor
    @Binding var selection: DeviceSelection?
    @State private var showAddMachine = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    Label("Fleet", systemImage: "square.grid.2x2")
                        .tag(DeviceSelection.fleet)
                    Label("This Mac", systemImage: "laptopcomputer")
                        .tag(DeviceSelection.thisMac)
                    ForEach(fleet.entries) { entry in
                        DeviceSidebarRow(
                            entry: entry,
                            isManual: entry.id.hasPrefix("manual:"),
                            onUnpair: { fleet.unpair(name: $0) },
                            onRemove: { fleet.removeManual(id: String(entry.id.dropFirst("manual:".count)),
                                                           name: entry.source.label) }
                        )
                        .tag(DeviceSelection.remote(entry.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if fleet.entries.isEmpty {
                        Label("Searching for agents…", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { showAddMachine = true } label: {
                        Label("Add machine…", systemImage: "plus")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Add an off-LAN machine (Tailscale / VPN / cloud) that isn't auto-discovered")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .sheet(isPresented: $showAddMachine) {
                AddMachineSheet(
                    onAdd: { name, host, port in fleet.addManual(name: name, host: host, port: port) },
                    onPairingLink: { fleet.applyPairingLink($0) }
                )
            }
        } detail: {
            switch selection ?? .thisMac {
            case .fleet:
                FleetOverviewView(fleet: fleet,
                                  onSelect: { selection = .remote($0) },
                                  onSelectLocal: { selection = .thisMac })
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
    let isManual: Bool
    let onUnpair: (String) -> Void
    let onRemove: () -> Void

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
            if isManual {
                Button("Remove machine", role: .destructive) { onRemove() }
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
