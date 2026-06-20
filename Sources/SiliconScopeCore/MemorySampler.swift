//
//  File:      MemorySampler.swift
//  Created:   2026-06-08
//  Updated:   2026-06-08
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads unified-memory usage and swap sudolessly via host_statistics64
//             (Mach VM stats) and sysctl. Stateless — sample() is a point reading.
//  Notes:     usedBytes = app + wired + compressed (Activity Monitor style), where
//             app = internal - purgeable. Page size is vm_kernel_page_size (16 KiB on
//             Apple Silicon). Total from hw.memsize; swap from vm.swapusage.
//
import Foundation

public final class MemorySampler {
    public init() {}

    public func sample() -> MemorySample {
        var result = MemorySample()
        result.totalBytes = Self.sysctlUInt64("hw.memsize")

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        if kr == KERN_SUCCESS {
            var rawPageSize: vm_size_t = 0
            host_page_size(host, &rawPageSize)
            let pageSize = UInt64(rawPageSize)
            result.wiredBytes = UInt64(stats.wire_count) * pageSize
            result.activeBytes = UInt64(stats.active_count) * pageSize
            result.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
            // Activity Monitor breakdown: App Memory = internal - purgeable (anonymous, not
            // evictable); Cached Files = external + purgeable (file-backed, reclaimable).
            let internalPages = UInt64(stats.internal_page_count)
            let purgeablePages = UInt64(stats.purgeable_count)
            let externalPages = UInt64(stats.external_page_count)
            result.appMemoryBytes = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
            result.cachedFilesBytes = (externalPages + purgeablePages) * pageSize
            // Cumulative lifetime counters (the monitor turns these into rates).
            result.compressions = UInt64(stats.compressions)
            result.swapins = UInt64(stats.swapins)
            result.swapouts = UInt64(stats.swapouts)
            result.pageins = UInt64(stats.pageins)
            result.pageouts = UInt64(stats.pageouts)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            result.swapTotalBytes = swap.xsu_total
            result.swapUsedBytes = swap.xsu_used
        }

        // macOS memory pressure level (1 = normal, 2 = warning/yellow, 4 = critical/red).
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            switch level {
            case 4: result.pressure = .critical
            case 2: result.pressure = .warning
            default: result.pressure = .normal
            }
        }

        return result
    }

    private static func sysctlUInt64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }
}
