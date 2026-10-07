//
//  File:      Network.swift
//  Created:   2026-06-08
//  Updated:   2026-10-09
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Network throughput (download/upload bytes per second) sampled sudolessly
//             via getifaddrs. Stateful: diffs interface byte counters against the
//             previous call.
//  Notes:     Sums AF_LINK counters across up, non-loopback, non-tunnel physical interfaces.
//             Virtual tunnel interfaces (utun*, ipsec*, etc.) are excluded so traffic isn't
//             double-counted against the physical transport. Counters can wrap (32-bit);
//             a counter that goes backwards yields 0 for that interval.
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
    /// Per-interface breakdown for active physical interfaces with an IP address, in fixed order.
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
    // Maximum interface rows to report in the breakdown to keep dashboard card height fixed.
    public static let maxInterfaceRows = 2

    // Per-interface counters from the previous tick, keyed by BSD name.
    private var previousIn:  [String: UInt64] = [:]
    private var previousOut: [String: UInt64] = [:]
    private var previousTimeNs: UInt64 = 0

    // Cached BSD name -> Display name map from SystemConfiguration.
    private var nameCache: [String: String] = [:]

    public init() {
        refreshNameCache()
    }

    /// Resolves the friendly display name for a BSD name using the cache, refreshing only on cache miss.
    private func displayName(for bsdName: String) -> String {
        if let cached = nameCache[bsdName] {
            return cached
        }
        refreshNameCache()
        if let resolved = nameCache[bsdName] {
            return resolved
        }
        nameCache[bsdName] = bsdName
        return bsdName
    }

    private func refreshNameCache() {
        if let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in list {
                if let bsd  = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let disp = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                    nameCache[bsd] = disp
                }
            }
        }
    }

    /// Identifies virtual tunnel / loopback / internal diagnostic interfaces that should not
    /// be counted in physical network totals to avoid double-counting inner VPN traffic.
    public static func isVirtualOrTunnel(bsdName: String) -> Bool {
        let prefixes = ["utun", "tun", "tap", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "p2p", "anpi", "dummy"]
        return prefixes.contains { bsdName.hasPrefix($0) }
    }

    private struct InterfaceRawInfo {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var hasAddress: Bool = false
    }

    public func sample() -> NetworkSample {
        let raw = Self.scanInterfaces()
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
            var stats: [InterfaceStat] = []

            // Sort BSD names for deterministic, stable interface ordering across ticks.
            let sortedBsdNames = raw.keys.sorted()

            for bsd in sortedBsdNames {
                guard let info = raw[bsd] else { continue }
                let prevIn  = previousIn[bsd]  ?? info.bytesIn
                let prevOut = previousOut[bsd] ?? info.bytesOut
                let deltaInBytes  = info.bytesIn  >= prevIn  ? info.bytesIn  - prevIn  : 0
                let deltaOutBytes = info.bytesOut >= prevOut ? info.bytesOut - prevOut : 0

                totalIn  += deltaInBytes
                totalOut += deltaOutBytes

                // Include active interfaces that are up and configured with an IP address.
                // Quiet interfaces are retained at 0 B/s to prevent UI jumping.
                if info.hasAddress {
                    let rateIn  = Double(deltaInBytes)  / seconds
                    let rateOut = Double(deltaOutBytes) / seconds
                    let dispName = displayName(for: bsd)
                    stats.append(InterfaceStat(name: dispName, bsdName: bsd,
                                               downloadBytesPerSec: rateIn,
                                               uploadBytesPerSec: rateOut))
                }
            }

            result.downloadBytesPerSec = Double(totalIn)  / seconds
            result.uploadBytesPerSec   = Double(totalOut) / seconds
            // Stable set capped to maxInterfaceRows so card height stays fixed.
            result.interfaces = Array(stats.prefix(Self.maxInterfaceRows))
        }

        // Latch current counters for next tick.
        for (bsd, info) in raw {
            previousIn[bsd]  = info.bytesIn
            previousOut[bsd] = info.bytesOut
        }
        previousTimeNs = now
        return result
    }

    /// Scans getifaddrs and returns byte counters and address status for non-tunnel, up interfaces.
    private static func scanInterfaces() -> [String: InterfaceRawInfo] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return [:] }
        defer { freeifaddrs(addrs) }

        var out: [String: InterfaceRawInfo] = [:]
        var pointer = addrs
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let ifaName = entry.pointee.ifa_name else { continue }
            let bsd = String(cString: ifaName)
            guard !isVirtualOrTunnel(bsdName: bsd) else { continue }

            guard let addr = entry.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_LINK) {
                if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    var info = out[bsd] ?? InterfaceRawInfo()
                    info.bytesIn = UInt64(data.pointee.ifi_ibytes)
                    info.bytesOut = UInt64(data.pointee.ifi_obytes)
                    out[bsd] = info
                }
            } else if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var info = out[bsd] ?? InterfaceRawInfo()
                info.hasAddress = true
                out[bsd] = info
            }
        }
        return out
    }
}
