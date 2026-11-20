//
//  File:      NetworkAddressesView.swift
//  Created:   2026-10-15
//  Updated:   2026-11-20
//  Developer: SiliconScope contributors
//  Overview:  Snapshot interface rows with compact local addresses and expandable full details.
//  Notes:     Never samples live interfaces from a view, including during replay.
//
import SwiftUI
import SiliconScopeCore

struct NetworkAddressesView: View {
    let network: NetworkSample
    private var interfaces: [InterfaceStat] { Array(network.interfaces.prefix(NetworkSampler.maxInterfaceRows)) }
    private var otherAddresses: [NetworkAddress] {
        let shown = Set(interfaces.map(\.bsdName))
        return (network.localAddresses ?? []).filter { !shown.contains($0.interface) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            ForEach(interfaces) { iface in
                DisclosureGroup {
                    VStack(alignment: .trailing, spacing: Space.hair) {
                        Text("↓ \(formatRate(iface.downloadBytesPerSec))  ↑ \(formatRate(iface.uploadBytesPerSec))")
                            .foregroundStyle(Theme.dim)
                        addressDetails(network.addresses(for: iface.bsdName))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } label: {
                    HStack(spacing: Space.row) {
                        // The interface name gives way, never the address: half an IP
                        // ("192.1…8.108") is not an address anyone can use.
                        CompactDisclosureTitle(iface.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: Space.hair)
                        headlineAddress(network.addresses(for: iface.bsdName)?.first)
                    }
                }
                .help("\(iface.name) (\(iface.bsdName)) — local addresses from getifaddrs. Default-route labels use SystemConfiguration. Expand for full copyable addresses and interface rates.")
            }
            if !otherAddresses.isEmpty {
                DisclosureGroup(interfaces.isEmpty ? "Addresses" : "More addresses") {
                    addressDetails(otherAddresses)
                }
                .help("Other interfaces reported by this snapshot, including VPN tunnels excluded from physical throughput totals.")
            } else if interfaces.isEmpty {
                HStack {
                    Text("Addresses").foregroundStyle(Theme.dim)
                    Spacer(minLength: Space.hair)
                    Text(network.localAddresses == nil ? "—" : "None reported").foregroundStyle(Theme.dim)
                }
            }
        }
        .font(Theme.font(.caption)).tint(Theme.dim)
        .disclosureGroupStyle(CompactDisclosureStyle())
    }
    /// An IPv4 address always shows whole. An IPv6 one (only when the interface has no IPv4) can
    /// be wider than the column, so it shrinks and then cuts at the end; the expanded row below
    /// always has it in full and copyable.
    @ViewBuilder private func headlineAddress(_ address: NetworkAddress?) -> some View {
        if let address, address.isIPv6 {
            Text(verbatim: address.address).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.75).truncationMode(.tail).layoutPriority(1)
        } else {
            Text(verbatim: address?.address ?? "—").foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize().layoutPriority(1)
        }
    }

    private func addressDetails(_ addresses: [NetworkAddress]?) -> some View {
        VStack(alignment: .trailing, spacing: Space.hair) {
            if let addresses, !addresses.isEmpty {
                ForEach(addresses) { ip in
                    Text("\(ip.interface) · \(ip.isIPv6 ? "IPv6" : "IPv4")\(ip.isPrimary ? " · default route" : "")")
                        .foregroundStyle(Theme.faint)
                    Text(ip.address).foregroundStyle(Theme.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(addresses == nil ? "Addresses unavailable in this snapshot" : "No usable address reported")
                    .foregroundStyle(Theme.faint)
            }
        }
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
