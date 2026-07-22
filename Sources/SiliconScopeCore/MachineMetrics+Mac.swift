//
//  File:      MachineMetrics+Mac.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Maps a local Apple-Silicon live snapshot (SystemSnapshot + CPUTopology) into the
//             source-agnostic MachineMetrics wire schema, so a Mac can serve itself to the fleet the
//             same way the Linux agent does. Fills the Apple-only block (E/P split, ANE/Media,
//             per-requestor bandwidth, power breakdown, fans) that has no counterpart on Linux.
//  Notes:     Pure — no I/O. Values outside SystemSnapshot (1-min load average, ANE/Media peaks for
//             bar-scaling) are passed in by the caller (app share-mode reads them off the monitor's
//             engine-derived vars; the CLI agent computes them). Usage fractions in the snapshot are
//             0…1, so they're ×100 here; a single blended CPU% is core-count-weighted across E/P.
//             Unified memory means "VRAM" is in-use GPU bytes against total physical RAM.
//
import Foundation

public extension MachineMetrics {
    static func mac(snapshot s: SystemSnapshot,
                    topology: CPUTopology?,
                    hostname: String,
                    machineId: String,
                    osName: String,
                    agentVersion: String,
                    tsMillis: Int64,
                    loadAvg1: Double,
                    anePeakWatts: Double,
                    mediaPeakGBs: Double,
                    bandwidthPeakGBs: Double) -> MachineMetrics {
        let eCores = topology?.eCoreCount ?? 0
        let pCores = topology?.pCoreCount ?? 0
        let coreDivisor = Double(max(eCores + pCores, 1))
        // Single CPU% blended from the two clusters, weighted by core counts.
        let blended = (s.cpu.eUsage * Double(eCores) + s.cpu.pUsage * Double(pCores)) / coreDivisor * 100

        let cpu = FleetCPU(
            cores: eCores + pCores,
            usagePercent: blended,
            loadAvg1: loadAvg1,
            eUsagePercent: s.cpu.eUsage * 100,
            pUsagePercent: s.cpu.pUsage * 100,
            eFreqMHz: s.cpu.eFreqMHz,
            pFreqMHz: s.cpu.pFreqMHz,
            eCores: eCores, pCores: pCores
        )

        let memory = FleetMemory(
            totalBytes: Int64(s.memory.totalBytes),
            usedBytes: Int64(s.memory.usedBytes),
            availableBytes: Int64(s.memory.freeBytes),
            // Full VM split, so the viewer's Memory card shows the real breakdown rather than zeros.
            wiredBytes: Int64(s.memory.wiredBytes),
            activeBytes: Int64(s.memory.activeBytes),
            compressedBytes: Int64(s.memory.compressedBytes),
            appMemoryBytes: Int64(s.memory.appMemoryBytes),
            cachedFilesBytes: Int64(s.memory.cachedFilesBytes),
            swapUsedBytes: Int64(s.memory.swapUsedBytes),
            swapTotalBytes: Int64(s.memory.swapTotalBytes),
            pressure: s.memory.pressure.rawValue
        )

        let chip = topology?.chipName ?? "Apple Silicon"
        // Unified memory: GPU "VRAM" = bytes the GPU is using now, against total physical RAM.
        let gpu = FleetGPU(
            index: 0,
            name: chip,
            driver: "Apple",
            vramTotalBytes: Int64(s.memory.totalBytes),
            vramUsedBytes: Int64(s.gpu.inUseMemoryBytes),
            utilizationPercent: s.gpu.usage * 100,
            temperatureC: s.temperature.gpuCelsius,
            powerDrawW: s.power.gpuWatts,
            powerLimitW: 0,
            processes: [],
            freqMHz: s.gpu.freqMHz
        )

        let apple = FleetApple(
            chip: chip,
            aneWatts: s.power.aneWatts,
            anePeakWatts: anePeakWatts,
            mediaGBs: s.bandwidth.mediaGBs,
            mediaPeakGBs: mediaPeakGBs,
            socWatts: s.power.socWatts,
            power: FleetPower(
                cpuWatts: s.power.cpuWatts,
                eCpuWatts: s.power.eCPUWatts,
                pCpuWatts: s.power.pCPUWatts,
                gpuWatts: s.power.gpuWatts,
                aneWatts: s.power.aneWatts,
                dramWatts: s.power.dramWatts
            ),
            bandwidth: FleetBandwidth(
                cpuGBs: s.bandwidth.cpuGBs,
                gpuGBs: s.bandwidth.gpuGBs,
                mediaGBs: s.bandwidth.mediaGBs,
                otherGBs: s.bandwidth.otherGBs,
                totalGBs: s.bandwidth.totalGBs,
                isEstimated: s.bandwidth.isEstimated,
                totalPeakGBs: bandwidthPeakGBs
            ),
            fanRPMs: s.thermal.fanRPMs
        )

        return MachineMetrics(
            machineId: machineId, hostname: hostname, os: osName, kind: "mac",
            agentVersion: agentVersion, ts: tsMillis, cpu: cpu, memory: memory,
            gpus: [gpu], llm: nil, apple: apple
        )
    }
}
