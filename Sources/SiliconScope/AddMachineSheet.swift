//
//  File:      AddMachineSheet.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Sheet for manually adding a fleet machine that isn't on the local network — a lab/office
//             GPU box or cloud instance reached over Tailscale, a VPN, or an SSH tunnel (mDNS only
//             auto-discovers the local subnet). Collects a name, host (IP / hostname / Tailscale
//             MagicDNS name), and port; the caller stores it and the machine then appears in the
//             sidebar/overview to pair (paste token) like any discovered agent.
//  Notes:     Port defaults to 7799 (the agent's default). Name defaults to the host if left blank.
//             The connection is TLS-encrypted + token-authenticated regardless of transport, so a
//             manual endpoint is exactly as secure as a discovered one.
//
import SwiftUI

struct AddMachineSheet: View {
    let onAdd: (_ name: String, _ host: String, _ port: Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "7799"

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portValue: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool { !trimmedHost.isEmpty && (portValue.map { $0 > 0 && $0 < 65_536 } ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                Text("Add a machine").font(.headline)
            }
            Text("For a GPU box or Mac that isn't on this network — reached over Tailscale, a VPN, or an SSH tunnel (mDNS only auto-discovers the local subnet). Enter its address; you'll paste its pairing token next. The link is TLS-encrypted and token-authenticated either way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("e.g. lab-3090 (optional)", text: $name)
                        .textFieldStyle(.roundedBorder).onSubmit(commit)
                }
                GridRow {
                    Text("Host").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("IP, hostname, or Tailscale name", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).onSubmit(commit)
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    TextField("7799", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).frame(width: 90).onSubmit(commit)
                }
            }
            .font(.callout)

            Label("Over Tailscale, use the tailnet IP (100.x…) or MagicDNS name. Prefer Tailscale / an SSH tunnel over exposing the port to the public internet.",
                  systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { commit() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func commit() {
        guard valid, let p = portValue else { return }
        onAdd(trimmedName.isEmpty ? trimmedHost : trimmedName, trimmedHost, p)
        dismiss()
    }
}
