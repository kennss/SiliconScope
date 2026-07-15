//
//  File:      main.swift
//  Created:   2026-06-08
//  Updated:   2026-07-15
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
        ollamaPort: 11434, lmStudioPort: 1234, omlxPort: 8000, omlxApiKey: "")
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

// On-demand benchmark (one short generation). Run: sscope-cli --bench
if CommandLine.arguments.contains("--bench") {
    let kind = ai.primaryKind
    let api = await RuntimeAPIClient().probe(
        primaryKind: kind, ollamaEmbeddedPort: ai.ollamaEmbeddedPort,
        ollamaPort: 11434, lmStudioPort: 1234, omlxPort: 8000, omlxApiKey: "")
    if let kind, let model = api.loadedModels.first?.name {
        let port = switch kind { case .lmStudio: 1234; case .rapidMLX: 8000; case .exo: 52415; case .omlx: 8000; default: 11434 }
        print("\nbenchmark: \(kind.displayName) · \(model) — generating…")
        if let r = await BenchmarkClient().run(kind: kind, port: port, model: model, apiKey: nil) {
            print(String(format: "  decode: %.1f tok/s  (%d tokens)", r.tokensPerSec, r.tokenCount))
            if let p = r.promptTokensPerSec { print(String(format: "  prefill: %.0f tok/s", p)) }
        } else {
            print("  benchmark failed — is the runtime's local server reachable?")
        }
    } else {
        print("\nbenchmark: no runtime with a loaded model (start the server / load a model)")
    }
}

// Sensor dump for verifying / contributing per-chip temperature key tables.
// Run: sscope-cli --sensors   (paste the output into a sensor-key contribution issue)
if CommandLine.arguments.contains("--sensors") {
    let readout = TemperatureSampler().curatedReadout()
    print("\n=== curated SMC keys — generation: \(readout.generation) ===")
    if readout.entries.isEmpty {
        print("  (no curated table for this generation — falls back to HID; see raw list below)")
    }
    var hit = 0
    for e in readout.entries {
        if let c = e.celsius { hit += 1; print(String(format: "  %-5@ %-10@ %5.1f C", e.key as NSString, e.name as NSString, c)) }
        else { print(String(format: "  %-5@ %-10@     —  (not present)", e.key as NSString, e.name as NSString)) }
    }
    if !readout.entries.isEmpty { print("  → \(hit)/\(readout.entries.count) curated keys read back") }

    let hid = HIDSensorReader.read().sorted { $0.name < $1.name }
    print("\n=== raw HID sensors (\(hid.count)) — use these to build/fix a table ===")
    for s in hid { print(String(format: "  %-26@ %5.1f C", s.name as NSString, s.celsius)) }

    // What the dashboard/menu-bar panel actually shows when the curated SMC path is empty
    // (base chips like M1 Air): the HID set after friendlyHID labeling + category grouping.
    let panel = TemperatureSampler().hidClassifiedSample()
    print("\n=== as the panel displays (friendlyHID → groups) ===")
    for g in panel.groups {
        print(String(format: "  [%@]  avg %.1f C · max %.1f C", g.category.rawValue as NSString, g.average, g.maximum))
        for s in g.sensors { print(String(format: "    %-18@ %5.1f C", s.name as NSString, s.celsius)) }
    }
    print("\nMac model: run `sysctl hw.model machdep.cpu.brand_string` and include it.")
}

// Power-channel dump for verifying / contributing per-chip power rails (e.g. where ANE power
// is exposed on M2). Run: sscope-cli --power-debug   (paste the output into a power issue).
if CommandLine.arguments.contains("--power-debug") {
    let lines = PowerSampler.channelDump()
    print("\n=== IOReport power channels (all groups, energy/Simple format) — \(lines.count) ===")
    print("Grep for ANE/Neural here. SiliconScope's aneWatts currently reads only the")
    print("\"Energy Model\" group; if ANE power shows up under another group (e.g. PMP), that")
    print("explains a 0 reading. Tip: run a webcam app (Photo Booth) to actually exercise the ANE.")
    for l in lines { print("  \(l)") }
    print("\nMac model: run `sysctl hw.model machdep.cpu.brand_string` and include it.")
}

// Full SMC temperature-key dump for mapping sensors on chips not in the curated table.
// Run: sscope-cli --sensors-all   (paste into a sensor-key contribution issue)
if CommandLine.arguments.contains("--sensors-all") {
    let gen = SensorCatalog.detectGeneration()
    let curated = Set(SensorCatalog.curated(for: gen).map(\.key))
    let all = TemperatureSampler().allSMCKeys()
    print("\n=== all present SMC \"T*\" keys — generation: \(gen) (\(all.count) keys) ===")
    print("  (* = present on this chip but NOT in our curated table — candidate for a missing sensor)")
    for e in all {
        let mark = curated.contains(e.key) ? " " : "*"
        let val = e.celsius.map { String(format: "%5.1f C", $0) } ?? "   —  "
        print(String(format: "  %@ %-5@ [%-4@] %@", mark as NSString, e.key as NSString, e.type as NSString, val as NSString))
    }
    print("\nMac model: run `sysctl hw.model machdep.cpu.brand_string` and include it.")
}

// Full SMC key dump — ALL keys incl. power (P*), current (I*), voltage (V*) — for discovering a
// chip's SMC power layout (e.g. A18 system power PSTR, CPU/GPU rails). Run: sscope-cli --smc-all
if CommandLine.arguments.contains("--smc-all") {
    let all = TemperatureSampler().allSMCKeysFull()
    let piv = all.filter { ["P", "I", "V"].contains($0.key.first.map(String.init) ?? "") }
    print("\n=== SMC power / current / voltage keys (P* / I* / V*) — \(piv.count) ===")
    print("  Looking for: system power PSTR, adapter PDTR, battery power, and any CPU/GPU power rails.")
    for e in piv {
        let v = e.value.map { String(format: "%.3f", $0) } ?? "—"
        print(String(format: "  %-5@ [%-4@] %@", e.key as NSString, e.type as NSString, v as NSString))
    }
    print("\n=== all SMC keys (\(all.count)) ===")
    for e in all {
        let v = e.value.map { String(format: "%.3f", $0) } ?? "—"
        print(String(format: "  %-5@ [%-4@] %@", e.key as NSString, e.type as NSString, v as NSString))
    }
    print("\nMac model: run `sysctl hw.model machdep.cpu.brand_string` and include it.")
}

// Raw bandwidth-channel dump for verifying / fixing the memory-bandwidth requestor map on a
// chip/OS combination BandwidthSampler doesn't classify correctly (e.g. 0 GB/s CPU/GPU bandwidth
// under real load — see github.com/kennss/SiliconScope#14). Run: sscope-cli --bandwidth
// (run it under a sustained CPU/GPU workload and paste the output into a bandwidth issue).
if CommandLine.arguments.contains("--bandwidth") {
    let lines = BandwidthSampler.channelDump()
    print("\n=== IOReport bandwidth channels (raw inventory) — \(lines.count) ===")
    print("Run this under sustained CPU/GPU memory traffic. Channels reading \"— (not populated)\"")
    print("carry the INT64_MIN sentinel instead of real bytes; that's a distinct problem from a")
    print("channel simply not being classified yet.")
    for l in lines { print("  \(l)") }
    print("\nMac model: run `sysctl hw.model machdep.cpu.brand_string` and include it.")
}

// Connected-peripheral battery levels (Apple Magic Mouse/Trackpad/Keyboard etc., sudoless via
// IORegistry BatteryPercent). Run: sscope-cli --peripherals
if CommandLine.arguments.contains("--peripherals") {
    let devices = PeripheralBatterySampler().sample()
    print("\n=== peripheral battery (\(devices.count)) — sudoless (IORegistry + system_profiler) ===")
    if devices.isEmpty {
        print("  (none — no connected device reports a battery value via IORegistry / system_profiler)")
    }
    for d in devices {
        let extra = d.detail.map { "  (\($0))" } ?? ""
        print(String(format: "  %-22@ %-9@ %3d%%%@",
                     d.name as NSString, d.kind.rawValue as NSString, d.percent, extra as NSString))
    }
}
