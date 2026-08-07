//
//  File:      VolumeSampler.swift
//  Created:   2026-06-19
//  Updated:   2026-08-07
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Enumerates mounted volumes (local + network) with capacity/free, sudolessly
//             via FileManager resource values. Powers the SSD/Disk menu-bar dropdown's
//             per-volume list (iStat "DISKS" / "NETWORK DISKS").
//  Notes:     Browsable volumes only (skips system/hidden). volumeIsLocal splits local vs
//             network mounts. Per-volume I/O is intentionally omitted (needs per-BSD-device
//             IOKit stats); aggregate R/W comes from the existing DiskSampler.
//
import Foundation

public struct VolumeInfo: Sendable, Identifiable, Equatable {
    public let name: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isLocal: Bool
    public var id: String { name }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - min(max(freeBytes, 0), totalBytes)) / Double(totalBytes) : 0
    }
}

public enum VolumeSampler {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeIsLocalKey, .volumeIsBrowsableKey,
    ]

    public static func sample() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for url in urls {
            guard let r = try? url.resourceValues(forKeys: keys),
                  r.volumeIsBrowsable == true,
                  let total = r.volumeTotalCapacity, total > 0 else { continue }
            out.append(VolumeInfo(
                name: r.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(total),
                freeBytes: Int64(r.volumeAvailableCapacity ?? 0),
                isLocal: r.volumeIsLocal ?? true))
        }
        // Local first, then by name.
        return out.sorted { ($0.isLocal ? 0 : 1, $0.name) < ($1.isLocal ? 0 : 1, $1.name) }
    }
}
