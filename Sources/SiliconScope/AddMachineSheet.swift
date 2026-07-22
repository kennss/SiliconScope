//
//  File:      AddMachineSheet.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Sheet for adding a fleet machine. Two ways in: paste the `sscope://pair…` link an agent
//             installer printed — it carries name + address + port + token, so the machine is added
//             AND paired in one step — or type an address by hand for a box that isn't auto-discovered
//             (Tailscale / VPN / SSH tunnel / cloud; mDNS only reaches the local subnet).
//  Notes:     Pasting into the Host field is enough: `absorbPairingLink` unpacks a recognized link
//             into every field and remembers the token, and the primary button becomes "Pair". An
//             edited host still wins on commit — that's how a LAN-printed link gets pointed at a
//             tailnet address. Port defaults to 7799; name defaults to the host. The connection is
//             TLS-encrypted + token-authenticated regardless of transport, so a manual endpoint is
//             exactly as secure as a discovered one.
//
import SwiftUI
import SiliconScopeCore

struct AddMachineSheet: View {
    let onAdd: (_ name: String, _ host: String, _ port: Int) -> Void
    let onPairingLink: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "7799"
    @State private var link: PairingLink?      // set when a pasted pairing link is recognized

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
            Text("Paste the pairing link the agent installer printed — it fills everything in and pairs in one step. Or enter an address by hand for a machine that isn't auto-discovered (Tailscale, a VPN, an SSH tunnel; mDNS only reaches the local subnet). Either way the link is TLS-encrypted and token-authenticated.")
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
                    TextField("Paste sscope://pair… or an IP / Tailscale name", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: host) { _, new in absorbPairingLink(new) }
                        .onSubmit(commit)
                }
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    TextField("7799", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).frame(width: 90).onSubmit(commit)
                }
            }
            .font(.callout)

            if link != nil {
                Label("Pairing link recognized — the token is included, so this machine pairs immediately.",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Over Tailscale, use the tailnet IP (100.x…) or MagicDNS name. Prefer Tailscale / an SSH tunnel over exposing the port to the public internet.",
                      systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(link != nil ? "Pair" : "Add") { commit() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// A pasted `sscope://pair…` link carries name + address + token, so unpack it into the fields
    /// (and remember the token) instead of making the user transcribe them separately.
    private func absorbPairingLink(_ text: String) {
        guard let parsed = PairingLink(text) else {
            if link != nil { link = nil }   // user edited it back into a plain host
            return
        }
        link = parsed
        host = parsed.host
        port = String(parsed.port)
        if trimmedName.isEmpty { name = parsed.name }
    }

    private func commit() {
        guard valid, let p = portValue else { return }
        if let link {
            // Keep the machine's own name as the pairing key (so a machine already found by mDNS
            // pairs in place instead of being listed twice), but honour an edited host/port — that's
            // how you point a LAN-printed link at a Tailscale address.
            onPairingLink(PairingLink(name: link.name, host: trimmedHost, port: p, token: link.token))
        } else {
            onAdd(trimmedName.isEmpty ? trimmedHost : trimmedName, trimmedHost, p)
        }
        dismiss()
    }
}
