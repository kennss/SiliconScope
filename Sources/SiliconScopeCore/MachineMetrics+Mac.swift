//
//  File:      MachineMetrics+Mac.swift
//  Created:   2026-07-22
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Maps a local Apple-Silicon live snapshot (SystemSnapshot + CPUTopology) into the
//             source-agnostic MachineMetrics wire schema, so a Mac can serve itself to the fleet the
//             same way the Linux agent does. Fills the Apple-only block (E/P split, ANE/Media,
//             per-requestor bandwidth, power breakdown, fans) that has no counterpart on Linux.
//  Notes:     Pure — no I/O. Values outside SystemSnapshot (1-min load average, ANE/Media peaks for
//             bar-scaling, the GPU-clock peak the throttle verdict reads) are passed in by the caller (app share-mode reads them off the monitor's
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
                    bandwidthPeakGBs: Double,
                    gpuClockPeakMHz: Double,
                    tokenRate: FleetTokenRate? = nil) -> MachineMetrics {
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
            eCores: eCores, pCores: pCores,
            // Sent on both architectures: sysctl knows the name whether or not IOReport does.
            model: topology?.chipName,
            // The chip's clock ceilings and cluster names. An empty table is sent as ABSENT: an
            // empty array would say "this chip has no DVFS steps", which is a claim, not a gap.
            eFreqsMHz: nonEmpty(topology?.eFreqsMHz),
            pFreqsMHz: nonEmpty(topology?.pFreqsMHz),
            eLevelName: topology?.eLevelName,
            pLevelName: topology?.pLevelName
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

        #if arch(x86_64)
        // Intel has none of this: no unified-memory GPU, ANE, or per-domain power (all IOReport).
        let gpus: [FleetGPU] = []
        let apple: FleetApple? = nil
        #else
        // Unified memory: GPU "VRAM" = bytes the GPU is using now, against total physical RAM.
        let gpus: [FleetGPU] = [FleetGPU(
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
        )]

        let apple: FleetApple? = FleetApple(
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
                dramWatts: s.power.dramWatts,
                windowSeconds: s.power.railWindowSeconds,
                gpuWindowSeconds: s.power.gpuWindowSeconds,
                systemWatts: s.power.systemWatts
            ),
            bandwidth: FleetBandwidth(
                cpuGBs: s.bandwidth.cpuGBs,
                gpuGBs: s.bandwidth.gpuGBs,
                mediaGBs: s.bandwidth.mediaGBs,
                otherGBs: s.bandwidth.otherGBs,
                totalGBs: s.bandwidth.totalGBs,
                isEstimated: s.bandwidth.isEstimated,
                totalPeakGBs: bandwidthPeakGBs,
                aneGBs: s.bandwidth.aneGBs
            ),
            fanRPMs: s.thermal.fanRPMs,
            gpuFreqsMHz: nonEmpty(topology?.gpuFreqsMHz),
            gpuClockPeakMHz: gpuClockPeakMHz > 0 ? gpuClockPeakMHz : nil,
            aneActiveFraction: s.ane?.activeFraction
        )
        #endif

        #if arch(x86_64)
        // Pressure is the kernel's own verdict and is equally true on Intel. Temperatures are not
        // sent here: the sensor map is Apple Silicon's, and an Intel Mac's SMC is a different key
        // space that #59 deliberately left out because nobody could verify it without the hardware.
        let thermal = FleetThermal(pressure: s.thermal.pressure.rawValue)
        #else
        let t = s.temperature
        // 0 °C is how the sampler says "no such sensor on this machine" (`hasCPU` etc.), so it is
        // sent as absent — a fanless Air with no battery reading must not arrive as a 0 °C battery.
        func present(_ c: Double) -> Double? { c > 0 ? c : nil }
        let thermal = FleetThermal(
            pressure: s.thermal.pressure.rawValue,
            cpuCelsius: present(t.cpuCelsius),
            cpuMaxCelsius: present(t.cpuMaxCelsius),
            gpuCelsius: present(t.gpuCelsius),
            batteryCelsius: present(t.batteryCelsius),
            sensors: t.groups.map { g in
                FleetSensorGroup(category: g.category.rawValue,
                                 sensors: g.sensors.map { FleetSensor(rawName: $0.rawName, name: $0.name, celsius: $0.celsius) })
            }
        )
        #endif

        // Disk and network come from IOKit block-storage counters, the volume's resource values and
        // the interface counters — none of it IOReport, so it is sent on both architectures.
        // Capacity is the boot volume, the same one this Mac's own Network & Disk card shows.
        let io = FleetIO(diskReadBytesPerSec: s.disk.readBytesPerSec,
                         diskWriteBytesPerSec: s.disk.writeBytesPerSec,
                         netDownBytesPerSec: s.network.downloadBytesPerSec,
                         netUpBytesPerSec: s.network.uploadBytesPerSec)
        let disks: [FleetDisk]? = s.disk.totalBytes > 0
            ? [FleetDisk(mount: "/", totalBytes: Int64(s.disk.totalBytes), freeBytes: Int64(s.disk.freeBytes))]
            : nil

        // Runtime identity comes from the process scan and is always known; what a runtime has
        // loaded comes from its API, which is only asked when the source chose to ask. A `.disabled`
        // sample means nobody asked, and that travels as ABSENT rather than as an empty answer.
        let api = s.runtimeAPI
        let aiRuntime = FleetAIRuntime(
            processes: s.aiRuntime.processes.map {
                FleetRuntimeProcess(pid: $0.pid, kind: $0.kind.rawValue,
                                    cpuPercent: $0.cpuPercent, memoryBytes: Int64($0.memoryBytes))
            },
            api: api.status == .disabled ? nil : FleetRuntimeAPI(
                status: api.status.rawValue, source: api.source?.rawValue,
                models: api.loadedModels.map {
                    FleetRuntimeModel(name: $0.name, sizeBytes: Int64($0.sizeBytes),
                                      sizeVRAMBytes: Int64($0.sizeVRAMBytes), parameterSize: $0.parameterSize,
                                      quantization: $0.quantization, contextLength: $0.contextLength)
                },
                tokensPerSec: api.tokensPerSec)
        )
        let battery: FleetBattery? = s.battery.hasBattery
            ? FleetBattery(percent: s.battery.percent, isCharging: s.battery.isCharging,
                           isPluggedIn: s.battery.isPluggedIn)
            : nil

        return MachineMetrics(
            machineId: machineId, hostname: hostname, os: osName, kind: "mac",
            agentVersion: agentVersion, ts: tsMillis, cpu: cpu, memory: memory,
            // A Mac serving models reports its decode rate the same way the Linux agent does, so
            // the fleet describes both in one vocabulary. nil when no runtime publishes one.
            gpus: gpus, llm: tokenRate.map { FleetLLM(ollama: nil, rate: $0) }, apple: apple,
            disks: disks, thermal: thermal, io: io,
            aiRuntime: aiRuntime, processes: Self.reportedProcesses(s.processes), battery: battery
        )
    }

    /// How many processes travel per ranking. The busiest by CPU and the largest by memory are
    /// sent — the union of both top lists, so either sort on the remote card starts from its real
    /// leaders — rather than the whole table, which runs to hundreds of rows every second.
    static let reportedProcessCount = 25

    static func reportedProcesses(_ rows: [ProcessRow]) -> [FleetProcess] {
        let byCPU = rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(reportedProcessCount)
        let byMemory = rows.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(reportedProcessCount)
        var seen = Set<Int32>()
        return (byCPU + byMemory).compactMap { r in
            guard seen.insert(r.pid).inserted else { return nil }
            return FleetProcess(pid: r.pid, name: r.name, cpuPercent: r.cpuPercent, memoryBytes: Int64(r.memoryBytes))
        }
    }

    private static func nonEmpty(_ values: [Double]?) -> [Double]? {
        guard let values, !values.isEmpty else { return nil }
        return values
    }
}
