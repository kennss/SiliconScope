//
//  File:      main.swift
//  Created:   2026-06-08
//  Updated:   2026-06-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Verification CLI for SiliconScopeCore. Prints sudoless power + CPU samples
//             so we can confirm the data layer works in a real SwiftPM build.
//  Notes:     Run with `xcrun swift run -q sscope-cli`. Sanity ranges: idle CPU power
//             well under load; P-cores should climb toward max DVFS MHz under load.
//
import Foundation
import SiliconScopeCore

guard let power = PowerSampler() else {
    FileHandle.standardError.write(Data("sscope: failed to subscribe to IOReport (power)\n".utf8))
    exit(1)
}
let cpu = CPUSampler()
let gpu: GPUSampler? = cpu.flatMap { GPUSampler(topology: $0.topology) }

if let topo = cpu?.topology {
    print("topology: \(topo.eCoreCount)E + \(topo.pCoreCount)P")
    print("E DVFS (MHz): \(topo.eFreqsMHz.map { Int($0) })")
    print("P DVFS (MHz): \(topo.pFreqsMHz.map { Int($0) })")
}

let memory = MemorySampler()
let thermal = ThermalSampler()
let bandwidth = BandwidthSampler()
let temperature = TemperatureSampler()

print("sscope probe — 3 samples (no sudo)")
for i in 1...3 {
    let p = power.sample(interval: 0.3)
    let c = cpu?.sample(interval: 0.3) ?? CPUSample()
    let g = gpu?.sample(interval: 0.3) ?? GPUSample()
    let m = memory.sample()
    let t = thermal.sample()
    let bw = bandwidth?.sample(interval: 0.3) ?? BandwidthSample()
    let tp = temperature.sample()
    let cpuLine = String(
        format: "E %3.0f%% @ %4.0f  P %3.0f%% @ %4.0f  GPU %3.0f%% @ %4.0f MHz",
        c.eUsagePercent, c.eFreqMHz, c.pUsagePercent, c.pFreqMHz, g.usagePercent, g.freqMHz
    )
    let pwrLine = String(
        format: "| E %4.1f P %4.1f GPU %4.1f ANE %4.1f DRAM %4.1f SoC %5.1f W",
        p.eCPUWatts, p.pCPUWatts, p.gpuWatts, p.aneWatts, p.dramWatts, p.socWatts
    )
    let memLine = String(
        format: "| MEM %.1f/%.0f GB (%.0f%%) wired %.1f swap %.1f",
        m.usedGB, m.totalGB, m.usedPercent, m.wiredGB, m.swapUsedGB
    )
    let fans = t.hasFans ? t.fanRPMs.map { String(format: "%.0f", $0) }.joined(separator: "/") : "none"
    let thermLine = String(
        format: "| CPU %.0f°C (max %.0f) batt %.0f°C thermal %@ fans %@",
        tp.cpuCelsius, tp.cpuMaxCelsius, tp.batteryCelsius, t.pressure.rawValue, fans
    )
    let bwLine = String(
        format: "| BW cpu %.0f gpu %.0f media %.0f other %.0f total %.0f GB/s",
        bw.cpuGBs, bw.gpuGBs, bw.mediaGBs, bw.otherGBs, bw.totalGBs
    )
    print("#\(i)  \(cpuLine)  \(pwrLine)  \(memLine)  \(bwLine)  \(thermLine)")
}

let budget = MemoryBudget.estimate(memory: memory.sample())
let reservedGB = Double(budget.reservedBytes) / (1024 * 1024 * 1024)
print(String(format: "\nmemory budget (ctx %d tok, reserve %.1f GB) — risk: %@",
             budget.contextTokens, reservedGB, budget.risk.rawValue))
print(String(format: "  headroom now %.1f GB · loadable %.1f GB", budget.headroomNowGB, budget.loadableGB))
print("  largest model that fits now: " + budget.fitsNow.map { $0.label }.joined(separator: " / "))

let processes = ProcessSampler()
_ = processes.sample(top: 1)            // prime CPU% baseline
try? await Task.sleep(for: .seconds(0.5))
let allRows = processes.sample(top: .max)
print("\ntop processes by CPU (no sudo):")
for p in allRows.prefix(8) {
    print(String(format: "  %6d  %6.1f%%  %8.1f MB   %@", p.pid, p.cpuPercent, p.memoryMB, p.name))
}

let ai = AIRuntimeSampler().sample(from: allRows)
print("\nAI runtimes detected: \(ai.isActive ? "" : "none")")
for p in ai.processes {
    let port = p.embeddedPort.map { " :\($0)" } ?? ""
    print(String(format: "  %@%@  pid %d  %.0f%% CPU  %.1f GB",
                 p.displayName, port, p.pid, p.cpuPercent, Double(p.memoryBytes) / 1e9))
}
if let kind = ai.primaryKind {
    print(String(format: "  primary: %@ (RSS %.1f GB) → budget loadable %.1f GB",
                 kind.displayName, Double(ai.primaryMemoryBytes) / 1e9, budget.loadableGB))
}

// Opt-in runtime API probe (one shot). Run: sscope-cli --ai
if CommandLine.arguments.contains("--ai") {
    let result = await RuntimeAPIClient().probe(
        primaryKind: ai.primaryKind, ollamaEmbeddedPort: ai.ollamaEmbeddedPort,
        ollamaPort: 11434, lmStudioPort: 1234)
    let src = result.source.map { " · \($0.rawValue)" } ?? ""
    print("\nruntime API: \(result.status.rawValue)\(src)")
    for m in result.loadedModels {
        var d = "  model: \(m.name)"
        if let p = m.parameterSize { d += " · \(p)" }
        if let q = m.quantization { d += " · \(q)" }
        if m.sizeBytes > 0 { d += String(format: " · %.1f GB", m.sizeGB) }
        if let split = m.processorLabel { d += " · \(split)" }
        if let ctx = m.contextLength { d += " · \(ctx) ctx" }
        print(d)
    }
    if let tps = result.tokensPerSec { print(String(format: "  tokens/sec: %.1f", tps)) }
}
