//
//  File:      MachineMetrics+Snapshot.swift
//  Created:   2026-07-22
//  Updated:   2026-07-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reverse mapping: synthesize a local-style SystemSnapshot (+ CPUTopology) from a remote
//             MachineMetrics, so the SAME DashboardView renders a remote Mac exactly like This Mac.
//             Only the hardware fields a Mac agent actually sends are filled; everything the wire
//             schema lacks (processes / network / disk / sensor groups / AI-runtime) stays zero, and
//             those cards are hidden in the dashboard's remote mode.
//  Notes:     Kept in Core so SystemSnapshot/CPUTopology's internal memberwise inits are reachable
//             (no need to make them public). Snapshot usage fractions are 0…1, so wire percents are
//             ÷100. "used" memory is placed in activeBytes so the stacked bar renders (wired/
//             compressed are unknown remotely). Only meaningful for kind == "mac" (apple != nil).
//
import Foundation

public extension MachineMetrics {
    /// Build the SystemSnapshot + CPUTopology that drive DashboardView for this remote machine.
    func toDashboardSnapshot() -> (snapshot: SystemSnapshot, topology: CPUTopology) {
        var s = SystemSnapshot()

        s.cpu.eUsage = (cpu.eUsagePercent ?? 0) / 100
        s.cpu.pUsage = (cpu.pUsagePercent ?? cpu.usagePercent) / 100
        s.cpu.eFreqMHz = cpu.eFreqMHz ?? 0
        s.cpu.pFreqMHz = cpu.pFreqMHz ?? 0

        s.memory.totalBytes = UInt64(max(memory.totalBytes, 0))
        s.memory.activeBytes = UInt64(max(memory.usedBytes, 0))   // used→active so the bar isn't blank

        if let g = gpus.first {
            s.gpu.usage = g.utilizationPercent / 100
            s.gpu.freqMHz = g.freqMHz ?? 0
            s.gpu.inUseMemoryBytes = UInt64(max(g.vramUsedBytes, 0))
            s.gpu.allocatedMemoryBytes = UInt64(max(g.vramTotalBytes, 0))
        }

        if let ap = apple {
            s.power.cpuWatts = ap.power.cpuWatts
            s.power.eCPUWatts = ap.power.eCpuWatts
            s.power.pCPUWatts = ap.power.pCpuWatts
            s.power.gpuWatts = ap.power.gpuWatts
            s.power.aneWatts = ap.power.aneWatts
            s.power.dramWatts = ap.power.dramWatts
            s.power.measuredSocWatts = ap.socWatts

            s.bandwidth.cpuGBs = ap.bandwidth.cpuGBs
            s.bandwidth.gpuGBs = ap.bandwidth.gpuGBs
            s.bandwidth.mediaGBs = ap.bandwidth.mediaGBs
            s.bandwidth.otherGBs = ap.bandwidth.otherGBs
            s.bandwidth.measuredTotalGBs = ap.bandwidth.totalGBs
            s.bandwidth.isEstimated = ap.bandwidth.isEstimated

            s.thermal.fanRPMs = ap.fanRPMs
        }
        s.temperature.gpuCelsius = gpus.first?.temperatureC ?? 0
        s.temperature.cpuCelsius = 0   // not sent remotely; die-temp history stays flat

        let topo = CPUTopology(
            chipName: apple?.chip ?? gpus.first?.name ?? "Apple Silicon",
            eCoreCount: cpu.eCores ?? 0,
            pCoreCount: cpu.pCores ?? cpu.cores,
            eFreqsMHz: [],
            pFreqsMHz: cpu.pFreqMHz.map { [$0] } ?? [],
            gpuFreqsMHz: []
        )
        return (s, topo)
    }
}
