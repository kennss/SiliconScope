//
//  File:      FleetMachineDetailView.swift
//  Created:   2026-07-22
//  Updated:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Detail pane for one fleet machine. When metrics are in, it renders the SAME
//             DashboardView the local "This Mac" uses — in remote mode, so a remote Mac looks
//             exactly like This Mac (E/P · GPU/Media/ANE · memory+bandwidth · sensors), minus the
//             cards a wire agent can't fill (network/disk/process/AI-runtime). Before metrics, it
//             shows pairing / error / connecting states.
//  Notes:     Remote data is mapped to a synthetic SystemSnapshot via DashboardState(remote:), so
//             all the dashboard's cards + verdict logic are reused with no duplication. Pairing is
//             in-place (token from the agent's Settings / installer).
//
import SwiftUI
import SiliconScopeCore

struct FleetMachineDetailView: View {
    let fleet: FleetMonitor
    let machineID: String
    @State private var showPairing = false

    private var entry: FleetMonitor.Entry? { fleet.entries.first { $0.id == machineID } }
    private var pairName: String { entry?.source.label ?? machineID }

    var body: some View {
        Group {
            // Pairing is checked BEFORE the cached metrics on purpose. `metrics` holds the last
            // successful poll, so an agent that has started answering 401 — its token rotated, or
            // this Mac was unpaired — would otherwise keep rendering that stale snapshot as if it
            // were current, AND hide the only button that can fix it. A machine we can no longer
            // authenticate against has no readings, whatever is still in the cache.
            if entry?.needsPairing == true {
                pairingPrompt
            } else if let m = entry?.metrics {
                if m.kind == "mac" {
                    // Reuse the local Mac dashboard (E/P · ANE · Media · bandwidth · fans).
                    DashboardView(state: DashboardState(remote: m), mode: .remote)
                } else {
                    // GPU-centric server view (NVIDIA util/VRAM/power/temp/processes) — no Apple cards.
                    LinuxServerView(fleet: fleet, machineID: machineID)
                }
            } else if let e = entry?.error {
                placeholder("exclamationmark.triangle", e, .red)
            } else {
                placeholder("hourglass", "Connecting…", .secondary)
            }
        }
        .navigationTitle(entry?.metrics?.hostname ?? entry?.source.label ?? machineID)
    }

    private var pairingPrompt: some View {
        VStack(spacing: Space.section) {
            Image(systemName: "lock.slash").font(.system(size: Icon.hero)).foregroundStyle(.orange)
            Text("Pairing required").font(Theme.font(.headline))
            Text("Enter this machine's token to connect securely.")
                .font(Theme.font(.emphasis)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Pair…") { showPairing = true }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.page)
        .sheet(isPresented: $showPairing) {
            PairingSheet(name: pairName) { token in fleet.pair(name: pairName, token: token) }
        }
    }

    private func placeholder(_ icon: String, _ text: String, _ color: Color) -> some View {
        VStack(spacing: Space.card) {
            Image(systemName: icon).font(.system(size: Icon.hero)).foregroundStyle(color)
            Text(text).font(Theme.font(.emphasis)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pairing sheet

/// Token-entry sheet for pairing a secure agent. The token comes from the agent's Settings (Mac) or
/// install-agent.sh output (Linux).
struct PairingSheet: View {
    let name: String
    let onPair: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack(spacing: Space.card) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("Pair \(name)").font(Theme.font(.headline))
            }
            Text("Enter the pairing token from this machine's SiliconScope Settings (Mac) or the install-agent.sh output (Linux). It encrypts and authenticates this connection.")
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
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
        .padding(Space.page)
        .frame(width: Layout.Surface.fleetDetailWidth)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onPair(trimmed)
        dismiss()
    }
}
