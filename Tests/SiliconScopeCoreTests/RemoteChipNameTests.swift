//
//  File:      RemoteChipNameTests.swift
//  Created:   2026-09-14
//  Updated:   2026-09-14
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in what a remote machine is called on screen, and in particular that a machine
//             which never told us its name is not called "Apple Silicon" (#56).
//  Notes:     The name used to travel only inside `apple.chip`. When an Intel Mac correctly stopped
//             sending that block it had nowhere left to say what it was, and the viewer's own
//             fallback printed "Apple Silicon" at a 2019 i9 — the fabrication moved from the agent
//             to the viewer rather than going away. `cpu.model` is the common home; the empty
//             string is a real answer, and the header renders nothing for it.
//
import XCTest
@testable import SiliconScopeCore

final class RemoteChipNameTests: XCTestCase {

    private func metrics(model: String? = nil,
                         gpus: [FleetGPU] = [],
                         apple: FleetApple? = nil,
                         cores: Int = 16) -> MachineMetrics {
        MachineMetrics(
            machineId: "m", hostname: "host", os: "macOS 15.6", kind: "mac",
            agentVersion: "1.1.0", ts: 0,
            cpu: FleetCPU(cores: cores, usagePercent: 4, loadAvg1: 1,
                          eUsagePercent: nil, pUsagePercent: 4,
                          eFreqMHz: nil, pFreqMHz: nil,
                          eCores: nil, pCores: nil, model: model),
            memory: FleetMemory(totalBytes: 32 << 30, usedBytes: 8 << 30, availableBytes: 24 << 30,
                                wiredBytes: nil, activeBytes: nil, compressedBytes: nil,
                                appMemoryBytes: nil, cachedFilesBytes: nil,
                                swapUsedBytes: nil, swapTotalBytes: nil, pressure: nil),
            gpus: gpus, llm: nil, apple: apple)
    }

    private func gpu(_ name: String) -> FleetGPU {
        FleetGPU(index: 0, name: name, driver: "d", vramTotalBytes: 1, vramUsedBytes: 0,
                 utilizationPercent: 0, temperatureC: 0, powerDrawW: 0, powerLimitW: 0,
                 processes: [], freqMHz: nil)
    }

    /// An Intel Mac sends no GPU and no Apple block. Its name has to come from the common one.
    func testIntelMacIsCalledWhatItSaysItIs() {
        let (_, topo) = metrics(model: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz").toDashboardSnapshot()
        XCTAssertEqual(topo.chipName, "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz")
        XCTAssertEqual(topo.pCoreCount, 16)
    }

    /// ⚠️ The regression. An agent too old to send a model name leaves us knowing nothing — and
    /// nothing must not render as "Apple Silicon".
    func testAMachineThatNeverSaidItsNameIsNotCalledAppleSilicon() {
        let (_, topo) = metrics(model: nil).toDashboardSnapshot()
        XCTAssertNotEqual(topo.chipName, "Apple Silicon")
        XCTAssertTrue(topo.chipName.isEmpty)
    }

    /// The Apple block still wins where it exists — it is the most specific thing we are sent.
    func testAppleBlockStillNamesAnAppleSiliconMac() {
        let apple = FleetApple(chip: "Apple M4 Max", aneWatts: 0, anePeakWatts: 1,
                               mediaGBs: 0, mediaPeakGBs: 1, socWatts: 0,
                               power: FleetPower(cpuWatts: 0, eCpuWatts: 0, pCpuWatts: 0,
                                                 gpuWatts: 0, aneWatts: 0, dramWatts: 0),
                               bandwidth: FleetBandwidth(cpuGBs: 0, gpuGBs: 0, mediaGBs: 0,
                                                         otherGBs: 0, totalGBs: 0,
                                                         isEstimated: false, totalPeakGBs: 1),
                               fanRPMs: [])
        let (_, topo) = metrics(model: "Apple M4 Max", gpus: [gpu("Apple M4 Max")], apple: apple)
            .toDashboardSnapshot()
        XCTAssertEqual(topo.chipName, "Apple M4 Max")
    }

    /// A Linux GPU box whose agent predates `model` keeps the heading it has always had.
    func testLinuxBoxWithoutAModelStillFallsBackToItsGPU() {
        let (_, topo) = metrics(model: nil, gpus: [gpu("NVIDIA GeForce RTX 3090")]).toDashboardSnapshot()
        XCTAssertEqual(topo.chipName, "NVIDIA GeForce RTX 3090")
    }

    /// Once that agent does send one, the CPU's own name outranks the GPU's.
    func testAModelNameOutranksTheGPUName() {
        let (_, topo) = metrics(model: "AMD Ryzen 9 5950X",
                                gpus: [gpu("NVIDIA GeForce RTX 3090")]).toDashboardSnapshot()
        XCTAssertEqual(topo.chipName, "AMD Ryzen 9 5950X")
    }

    /// Old payloads have no `model` key at all; decoding must not fail on its absence.
    func testAPayloadWithoutTheModelKeyStillDecodes() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"linux","kind":"linux","agentVersion":"0.1","ts":0,
         "cpu":{"cores":8,"usagePercent":3,"loadAvg1":0.5},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1}}
        """
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertNil(m.cpu.model)
        XCTAssertEqual(m.cpu.cores, 8)
    }
}
