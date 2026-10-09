//
//  File:      Network.swift
//  Created:   2026-06-08
//  Updated:   2026-10-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Network throughput (download/upload bytes per second) sampled sudolessly
//             via getifaddrs. Stateful: diffs interface byte counters against the
//             previous call.
//  Notes:     Sums AF_LINK counters across up, non-loopback, non-tunnel physical interfaces.
//             Virtual tunnel interfaces (utun*, ipsec*, etc.) are excluded so traffic isn't
//             double-counted against the physical transport. Counters can wrap (32-bit);
//             a counter that goes backwards yields 0 for that interval.
//             The breakdown lists interfaces with a routable address (link-local fe80:: and
//             169.254 alone don't count), the one carrying the default route first: sorted by
//             name, an internal link-local-only interface can take the place of the Ethernet
//             that carries the traffic. The primary interface comes from System Configuration
//             ("PrimaryInterface") and is re-read at most every `primaryRefresh` seconds.
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

    // The interface carrying the default route, re-read at most every `primaryRefresh` seconds:
    // it changes only when the network does (Wi-Fi ↔ Ethernet), not between ticks.
    private static let primaryRefresh: UInt64 = 5_000_000_000   // ns
    private let store = SCDynamicStoreCreate(nil, "SiliconScope.network" as CFString, nil, nil)
    private var primary: String?
    private var primaryReadNs: UInt64 = 0

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
        var hasRoutableAddress: Bool = false
    }

    /// System Configuration's primary interface (the default route), IPv4 first, then IPv6.
    private func primaryInterface(now: UInt64) -> String? {
        if primaryReadNs != 0, now &- primaryReadNs < Self.primaryRefresh { return primary }
        primaryReadNs = now
        primary = nil
        guard let store else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String {
                primary = name
                break
            }
        }
        return primary
    }

    /// The breakdown's order: the primary interface first, then the rest by name, so the
    /// interface carrying the traffic is never the one cut off by `maxInterfaceRows`.
    static func breakdownOrder(_ candidates: [String], primary: String?) -> [String] {
        let sorted = candidates.sorted()
        guard let primary, sorted.contains(primary) else { return sorted }
        return [primary] + sorted.filter { $0 != primary }
    }

    /// An IPv4 address outside 169.254.0.0/16 (self-assigned when nothing answered DHCP).
    static func isRoutableIPv4(_ octets: [UInt8]) -> Bool {
        octets.count == 4 && !(octets[0] == 169 && octets[1] == 254)
    }

    /// An IPv6 address outside fe80::/10 (link-local, present on every interface that is up).
    static func isRoutableIPv6(_ octets: [UInt8]) -> Bool {
        octets.count == 16 && !(octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80)
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

            // Primary interface first, then by name: a stable order that never cuts the
            // interface carrying the traffic.
            let ordered = Self.breakdownOrder(Array(raw.keys), primary: primaryInterface(now: now))

            for bsd in ordered {
                guard let info = raw[bsd] else { continue }
                let prevIn  = previousIn[bsd]  ?? info.bytesIn
                let prevOut = previousOut[bsd] ?? info.bytesOut
                let deltaInBytes  = info.bytesIn  >= prevIn  ? info.bytesIn  - prevIn  : 0
                let deltaOutBytes = info.bytesOut >= prevOut ? info.bytesOut - prevOut : 0

                totalIn  += deltaInBytes
                totalOut += deltaOutBytes

                // Include interfaces with a routable address. Quiet ones stay at 0 B/s so rows
                // don't come and go.
                if info.hasRoutableAddress {
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
            } else if family == UInt8(AF_INET) {
                let routable = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    withUnsafeBytes(of: sin.pointee.sin_addr) { isRoutableIPv4(Array($0)) }
                }
                if routable { out[bsd, default: InterfaceRawInfo()].hasRoutableAddress = true }
            } else if family == UInt8(AF_INET6) {
                let routable = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    withUnsafeBytes(of: sin6.pointee.sin6_addr) { isRoutableIPv6(Array($0)) }
                }
                if routable { out[bsd, default: InterfaceRawInfo()].hasRoutableAddress = true }
            }
        }
        return out
    }
}
