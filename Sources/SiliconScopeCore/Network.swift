//
//  File:      Network.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Network throughput (download/upload bytes per second) sampled sudolessly
//             via getifaddrs. Stateful: diffs interface byte counters against the
//             previous call.
//  Notes:     Sums AF_LINK counters across up, non-loopback interfaces. Counters can
//             wrap (32-bit); a counter that goes backwards yields 0 for that interval.
//
import Foundation

public struct NetworkSample: Sendable, Equatable, Codable {
    public var downloadBytesPerSec: Double = 0
    public var uploadBytesPerSec: Double = 0
    public init() {}
}

public final class NetworkSampler {
    private var previousIn: UInt64 = 0
    private var previousOut: UInt64 = 0
    private var previousTimeNs: UInt64 = 0

    public init() {}

    public func sample() -> NetworkSample {
        let (bytesIn, bytesOut) = Self.counters()
        let now = DispatchTime.now().uptimeNanoseconds

        var result = NetworkSample()
        if previousTimeNs > 0 {
            let seconds = Double(now &- previousTimeNs) / 1_000_000_000
            if seconds > 0 {
                result.downloadBytesPerSec = Double(bytesIn >= previousIn ? bytesIn - previousIn : 0) / seconds
                result.uploadBytesPerSec = Double(bytesOut >= previousOut ? bytesOut - previousOut : 0) / seconds
            }
        }
        previousIn = bytesIn
        previousOut = bytesOut
        previousTimeNs = now
        return result
    }

    private static func counters() -> (UInt64, UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return (0, 0) }
        defer { freeifaddrs(addrs) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var pointer = addrs
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                bytesIn += UInt64(data.pointee.ifi_ibytes)
                bytesOut += UInt64(data.pointee.ifi_obytes)
            }
        }
        return (bytesIn, bytesOut)
    }
}
