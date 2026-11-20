//
//  File:      SSDSMARTDetails.swift
//  Created:   2026-10-15
//  Updated:   2026-11-20
//  Developer: SiliconScope contributors
//  Overview:  Compact SSD health line with optional SMART details, and the dashboard's folded SSD
//             block (bytes since boot, lifetime bytes and SMART behind one line).
//  Notes:     Health is remaining rated endurance, never a failure prediction.
//             A SMART critical warning is never folded away: it shows under the line whether the
//             block is open or not. The dashboard block's open state persists ("dashboard.ssdExpanded").
//
import SwiftUI
import SiliconScopeCore

struct SSDSMARTDetails: View {
    let samples: [SSDSMARTSample]?
    var body: some View {
        if let samples, !samples.isEmpty {
            ForEach(samples) { sample in
                SSDSMARTDeviceDetails(sample: sample, showName: samples.count > 1)
            }
        } else {
            smartRow("SSD health", "—")
                .help("NVMe SMART unavailable. SATA and USB SMART are not queried.")
        }
    }
}

private struct SSDSMARTDeviceDetails: View {
    let sample: SSDSMARTSample
    let showName: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Space.hair) {
                    if !showName {
                        Text(sample.deviceName ?? "SSD SMART").foregroundStyle(Theme.faint)
                    }
                    SSDSMARTRows(sample: sample)
                }.padding(.top, Space.hair)
            } label: {
                smartRow(showName ? (sample.deviceName ?? "SSD health") : "SSD health",
                         "\(sample.remainingEndurancePercent)% remaining")
                    .help("Remaining rated endurance = max(0, 100 − NVMe Percentage Used). A vendor estimate, not a failure prediction; 0% does not mean the drive has failed. Expand for SMART details.")
            }
            .tint(Theme.dim)
            .disclosureGroupStyle(CompactDisclosureStyle())
            ForEach(sample.criticalWarnings, id: \.self) { warning in
                Text(warning).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
        }.font(Theme.font(.caption))
    }
}

/// The SMART fields of one drive, shared by the dropdown's health line and the dashboard block.
private struct SSDSMARTRows: View {
    let sample: SSDSMARTSample
    var body: some View {
        smartRow("Endurance used", "\(sample.enduranceUsedPercent)%")
        smartRow("Temperature", sample.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "—")
        smartRow("Spare capacity", sample.availableSparePercent.map { "\($0)%" } ?? "—")
        smartRow("Spare threshold", sample.spareThresholdPercent.map { "\($0)%" } ?? "—")
        smartRow("Data integrity errors", sample.mediaErrors.map { String($0) } ?? "—")
            .help("NVMe lifetime count of unrecovered media and data integrity errors (including ECC, CRC and LBA tag errors). Separate from OS read/write errors; no counters are combined.")
    }
}

/// The dashboard's SSD block folded to one line: "SSD health" and the remaining rated endurance
/// as a bare percentage ("SSD 96% remaining" under the Disk's capacity bar read as free space),
/// opening to the bytes moved since boot, the drive's lifetime bytes and its SMART fields. These
/// are readings to look up, not to watch, so they no longer take the Disk column's height.
struct SSDDetailsDisclosure: View {
    let disk: DiskSample
    let readColor: Color
    let writeColor: Color
    @AppStorage("dashboard.ssdExpanded") private var expanded = false

    private var samples: [SSDSMARTSample] { disk.ssdSMART ?? [] }

    /// One drive: its remaining endurance. Several: the lowest, which is the one to know about.
    private var summary: String {
        guard let worst = samples.map(\.remainingEndurancePercent).min() else { return "—" }
        return "\(worst)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    header("Since boot")
                        .help("Internal SSD host bytes from IOBlockStorageDriver counters matched at boot. — means unavailable, including an observed reset or device change. Activity includes all disks.")
                    bytesRow("Read", disk.ssdBootReadBytes, readColor)
                    bytesRow("Write", disk.ssdBootWriteBytes, writeColor)
                    header("Lifetime")
                        .help("Internal SSD lifetime host bytes from NVMe SMART data units (512,000 bytes), rounded by the device. — means unavailable.")
                    bytesRow("Read", disk.ssdLifetimeReadBytes, readColor)
                    bytesRow("Write", disk.ssdLifetimeWriteBytes, writeColor)
                    if samples.isEmpty {
                        smartRow("SMART", "—")
                            .help("NVMe SMART unavailable. SATA and USB SMART are not queried.")
                    }
                    ForEach(samples) { sample in
                        header(samples.count > 1 ? (sample.deviceName ?? "SMART") : "SMART")
                        SSDSMARTRows(sample: sample)
                    }
                }
                .padding(.top, Space.hair)
            } label: {
                smartRow("SSD health", summary)
                    .help("Remaining rated endurance = max(0, 100 − NVMe Percentage Used). A vendor estimate, not a failure prediction; 0% does not mean the drive has failed. Expand for bytes and SMART details.")
            }
            .tint(Theme.dim)
            .disclosureGroupStyle(CompactDisclosureStyle())
            // Never folded: a critical warning is the one thing here that must be seen unasked.
            ForEach(samples) { sample in
                ForEach(sample.criticalWarnings, id: \.self) { warning in
                    Text(warning).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Theme.font(.caption))
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.labelFont(.sectionMinor)).foregroundStyle(Theme.faint)
    }

    private func bytesRow(_ label: String, _ bytes: UInt64?, _ color: Color) -> some View {
        HStack(spacing: Space.row) {
            Text(label).foregroundStyle(Theme.dim)
            Spacer(minLength: Space.hair)
            Text(bytes.map(formatBytes) ?? "—").monospacedDigit().foregroundStyle(color)
        }
    }
}

private func smartRow(_ label: String, _ value: String) -> some View {
    HStack(spacing: Space.row) {
        CompactDisclosureTitle(label).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: Space.hair)
        Text(value).monospacedDigit().foregroundStyle(Theme.text)
    }.font(Theme.font(.caption))
}
