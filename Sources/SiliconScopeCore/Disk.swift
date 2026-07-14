//
//  File:      Disk.swift
//  Created:   2026-06-08
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Disk I/O throughput (read/write bytes per second) and boot-volume
//             capacity, sampled sudolessly. I/O via IOBlockStorageDriver statistics
//             (stateful diff); capacity via volume resource values.
//  Notes:     Sums "Bytes (Read)"/"Bytes (Write)" across all block storage drivers.
//             freeBytes uses AvailableCapacityForImportantUsage (purgeable-aware).
//
import Foundation
import IOKit

public struct DiskSample: Sendable, Equatable, Codable {
    public var readBytesPerSec: Double = 0
    public var writeBytesPerSec: Double = 0
    public var totalBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0

    public init() {}

    private static let gb = 1024.0 * 1024.0 * 1024.0
    public var totalGB: Double { Double(totalBytes) / Self.gb }
    public var freeGB: Double { Double(freeBytes) / Self.gb }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes) : 0
    }
}

public final class DiskSampler {
    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var previousTimeNs: UInt64 = 0

    // Capacity on a slow cadence: querying volumeAvailableCapacityForImportantUsage triggers
    // Apple's CacheDelete framework to re-validate EVERY mounted volume's purgeable space
    // (getattrlist/realpath/APFS-role IOKit storm on in-process queues — profiled at ~4% of a
    // core when run each tick). Free space doesn't change per-second; 30 s is plenty.
    // (docs/energy-optimization.md — closed-window cost investigation.)
    private var cachedCapacity: (total: UInt64, free: UInt64) = (0, 0)
    private var lastCapacitySample: Date = .distantPast
    private let capacityInterval: TimeInterval = 30

    public init() {}

    public func sample() -> DiskSample {
        var result = DiskSample()

        let (read, write) = Self.ioBytes()
        let now = DispatchTime.now().uptimeNanoseconds
        if previousTimeNs > 0 {
            let seconds = Double(now &- previousTimeNs) / 1_000_000_000
            if seconds > 0 {
                result.readBytesPerSec = Double(read >= previousRead ? read - previousRead : 0) / seconds
                result.writeBytesPerSec = Double(write >= previousWrite ? write - previousWrite : 0) / seconds
            }
        }
        previousRead = read
        previousWrite = write
        previousTimeNs = now

        if Date().timeIntervalSince(lastCapacitySample) >= capacityInterval {
            lastCapacitySample = Date()
            cachedCapacity = Self.capacity()
        }
        result.totalBytes = cachedCapacity.total
        result.freeBytes = cachedCapacity.free
        return result
    }

    private static func capacity() -> (UInt64, UInt64) {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (total, free)
    }

    private static func ioBytes() -> (UInt64, UInt64) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as NSDictionary?,
               let stats = dict["Statistics"] as? NSDictionary {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}
