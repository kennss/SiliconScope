//
//  File:      Network.swift
//  Created:   2026-06-08
//  Updated:   2026-10-01
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Network throughput (download/upload bytes per second) sampled sudolessly
//             via getifaddrs. Stateful: diffs interface byte counters against the
//             previous call.
//  Notes:     Sums AF_LINK counters across up, non-loopback interfaces. Counters can
//             wrap (32-bit); a counter that goes backwards yields 0 for that interval.
//             `interfaces` is an additive field: decode uses decodeIfPresent so older
//             recordings and fleet wire frames (which omit it) still decode as an empty
//             array rather than throwing .keyNotFound.
//
import Foundation
import SystemConfiguration

/// Per-interface throughput for one sample tick.
public struct InterfaceStat: Sendable, Equatable, Codable, Identifiable {
    /// Friendly display name from SystemConfiguration, e.g. "Wi-Fi", "Ethernet", "Thunderbolt Bridge".
    /// Falls back to the BSD name when SC has no display name.
    public var name: String
    /// BSD interface name, e.g. "en0".
    public var bsdName: String
    public var downloadBytesPerSec: Double
    public var uploadBytesPerSec: Double
    public var id: String { bsdName }

    public init(name: String, bsdName: String,
                downloadBytesPerSec: Double, uploadBytesPerSec: Double) {
        self.name = name
        self.bsdName = bsdName
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
    }
}

public struct NetworkSample: Sendable, Equatable, Codable {
    public var downloadBytesPerSec: Double = 0
    public var uploadBytesPerSec: Double = 0
    /// Per-interface breakdown, sorted by combined throughput descending.
    /// Empty on recordings / fleet frames that predate this field.
    public var interfaces: [InterfaceStat] = []

    public init() {}

    /// Hand-written decoder so `interfaces` decodes as [] when absent (older recordings /
    /// fleet wire), rather than throwing .keyNotFound and dropping the entire frame.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadBytesPerSec = try c.decodeIfPresent(Double.self, forKey: .downloadBytesPerSec) ?? 0
        uploadBytesPerSec   = try c.decodeIfPresent(Double.self, forKey: .uploadBytesPerSec)   ?? 0
        interfaces          = try c.decodeIfPresent([InterfaceStat].self, forKey: .interfaces)  ?? []
    }
}

public final class NetworkSampler {
    // Per-interface counters from the previous tick, keyed by BSD name.
    private var previousIn:  [String: UInt64] = [:]
    private var previousOut: [String: UInt64] = [:]
    // Aggregate totals for the headline figures.
    private var previousTotalIn:  UInt64 = 0
    private var previousTotalOut: UInt64 = 0
    private var previousTimeNs: UInt64 = 0

    // Friendly display names from SystemConfiguration, refreshed once per sample.
    // SC is fast (no IOKit), so reading each tick is fine.
    private static func friendlyNames() -> [String: String] {
        var map: [String: String] = [:]
        if let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in list {
                if let bsd  = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let disp = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                    map[bsd] = disp
                }
            }
        }
        return map
    }

    public init() {}

    public func sample() -> NetworkSample {
        let raw = Self.perInterfaceCounters()
        let now = DispatchTime.now().uptimeNanoseconds

        var result = NetworkSample()

        if previousTimeNs > 0 {
            let seconds = Double(now &- previousTimeNs) / 1_000_000_000
            guard seconds > 0 else {
                previousTimeNs = now
                return result
            }

            var totalIn:  UInt64 = 0
            var totalOut: UInt64 = 0
            let friendly = Self.friendlyNames()
            var stats: [InterfaceStat] = []

            for (bsd, (bytesIn, bytesOut)) in raw {
                let prevIn  = previousIn[bsd]  ?? bytesIn
                let prevOut = previousOut[bsd] ?? bytesOut
                let deltaIn  = Double(bytesIn  >= prevIn  ? bytesIn  - prevIn  : 0) / seconds
                let deltaOut = Double(bytesOut >= prevOut ? bytesOut - prevOut : 0) / seconds
                totalIn  += (bytesIn  >= prevIn  ? bytesIn  - prevIn  : 0)
                totalOut += (bytesOut >= prevOut ? bytesOut - prevOut : 0)
                // Only include interfaces that carried at least one byte this tick.
                if deltaIn > 0 || deltaOut > 0 {
                    let displayName = friendly[bsd] ?? bsd
                    stats.append(InterfaceStat(name: displayName, bsdName: bsd,
                                               downloadBytesPerSec: deltaIn,
                                               uploadBytesPerSec: deltaOut))
                }
            }

            result.downloadBytesPerSec = Double(totalIn)  / seconds
            result.uploadBytesPerSec   = Double(totalOut) / seconds
            // Busiest interface first (combined throughput).
            result.interfaces = stats.sorted {
                ($0.downloadBytesPerSec + $0.uploadBytesPerSec) >
                ($1.downloadBytesPerSec + $1.uploadBytesPerSec)
            }
        }

        // Latch current counters for next tick.
        for (bsd, (bytesIn, bytesOut)) in raw {
            previousIn[bsd]  = bytesIn
            previousOut[bsd] = bytesOut
        }
        previousTimeNs = now
        return result
    }

    /// Returns current absolute byte counters keyed by BSD interface name.
    private static func perInterfaceCounters() -> [String: (UInt64, UInt64)] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return [:] }
        defer { freeifaddrs(addrs) }

        var out: [String: (UInt64, UInt64)] = [:]
        var pointer = addrs
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let bsd = String(cString: entry.pointee.ifa_name)
            out[bsd] = (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        return out
    }
}
