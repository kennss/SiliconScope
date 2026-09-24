//
//  File:      RemoteThermalTests.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Locks in the first step of remote/local parity (#56): a remote Mac's thermal
//             pressure, temperatures and throttle verdicts, and the clock-ceiling bug they exposed.
//  Notes:     Round-trips go through real JSON on purpose. The failure modes worth guarding are
//             decode failures — an unknown enum value, a missing key — and those only exist at the
//             wire; constructing the Swift types directly would test around them.
//
import XCTest
@testable import SiliconScopeCore

final class RemoteThermalTests: XCTestCase {

    private let topology = CPUTopology(
        chipName: "Apple M1 Max", eCoreCount: 2, pCoreCount: 8,
        eFreqsMHz: [600, 972, 1332, 1704, 2064],
        pFreqsMHz: [600, 1056, 1524, 2064, 2604, 3036, 3228],
        gpuFreqsMHz: [389, 486, 648, 778, 1296])

    private func hotSnapshot() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu.pUsage = 0.9
        s.cpu.pFreqMHz = 2064                  // held well under the 3228 MHz ceiling
        s.gpu.usage = 0.8
        s.gpu.freqMHz = 648
        s.power.gpuWatts = 20
        s.thermal.pressure = .serious
        s.temperature.cpuCelsius = 94
        s.temperature.cpuMaxCelsius = 99
        s.temperature.gpuCelsius = 90
        s.temperature.groups = [
            SensorGroup(category: .cpu, sensors: [TempSensor(rawName: "Tp01", name: "P-core 1", celsius: 94)]),
            SensorGroup(category: .gpu, sensors: [TempSensor(rawName: "Tg0f", name: "GPU 1", celsius: 90)]),
        ]
        return s
    }

    private func roundTrip(_ m: MachineMetrics) throws -> MachineMetrics {
        try JSONDecoder().decode(MachineMetrics.self, from: JSONEncoder().encode(m))
    }

    private func served(_ s: SystemSnapshot, gpuPeak: Double = 1296) throws -> MachineMetrics {
        try roundTrip(.mac(snapshot: s, topology: topology, hostname: "studio", machineId: "m",
                           osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 1,
                           anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1,
                           gpuClockPeakMHz: gpuPeak))
    }

    // MARK: - What arrives

    func testPressureTemperaturesAndSensorRowsSurviveTheWire() throws {
        let (s, _) = try served(hotSnapshot()).toDashboardSnapshot()
        XCTAssertEqual(s.thermal.pressure, .serious)
        XCTAssertEqual(s.temperature.cpuCelsius, 94)
        XCTAssertEqual(s.temperature.cpuMaxCelsius, 99)
        XCTAssertEqual(s.temperature.gpuCelsius, 90)
        XCTAssertEqual(s.temperature.groups.map(\.category), [.cpu, .gpu])
        XCTAssertEqual(s.temperature.groups.first?.sensors.first?.rawName, "Tp01")
    }

    /// The sampler says "no such sensor" with 0 °C. On the wire that must be an absence, or a
    /// machine with no battery sensor arrives as a machine with a 0 °C battery.
    func testAMissingSensorIsSentAsAbsentNotAsZero() throws {
        var s = hotSnapshot()
        s.temperature.batteryCelsius = 0
        XCTAssertNil(try served(s).thermal?.batteryCelsius)
    }

    /// The cluster names travel. An M5 Max calls its top tier "Super"; a remote page that said
    /// "P-cores" would contradict the machine's own dashboard.
    func testClusterNamesTravel() throws {
        let m5 = CPUTopology(chipName: "Apple M5 Max", eCoreCount: 6, pCoreCount: 12,
                             eFreqsMHz: [1000], pFreqsMHz: [4600], gpuFreqsMHz: [],
                             pLevelName: "Super", eLevelName: "Performance")
        let m = try roundTrip(.mac(snapshot: hotSnapshot(), topology: m5, hostname: "h", machineId: "m",
                                   osName: "macOS 27.0", agentVersion: "1.2.0", tsMillis: 0, loadAvg1: 0,
                                   anePeakWatts: 1, mediaPeakGBs: 1, bandwidthPeakGBs: 1, gpuClockPeakMHz: 0))
        let (_, topo) = m.toDashboardSnapshot()
        XCTAssertEqual(topo.pLabel, "Super")
        XCTAssertEqual(topo.eLabel, "Performance")
    }

    // MARK: - The verdicts, computed viewer-side from the agent's references

    /// ⚠️ The bug this step exposed. The remote topology used to take the CURRENT P clock as its
    /// DVFS table, so the ceiling always equalled the reading and a throttle was unreportable.
    func testARemoteCPUThrottleIsNowReportable() throws {
        let (s, topo) = try served(hotSnapshot()).toDashboardSnapshot()
        XCTAssertEqual(topo.pFreqsMHz.max(), 3228, "the ceiling is the chip's, not the reading")
        XCTAssertTrue(MetricsEngine.cpuThrottling(latest: s, topology: topo))
        XCTAssertEqual(MetricsEngine.cpuClockDropFraction(latest: s, topology: topo), 1 - 2064.0 / 3228, accuracy: 1e-9)
    }

    func testARemoteGPUThrottleUsesTheAgentsObservedPeak() throws {
        let m = try served(hotSnapshot(), gpuPeak: 1296)
        let (s, _) = m.toDashboardSnapshot()
        XCTAssertTrue(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: m.apple?.gpuClockPeakMHz ?? 0))
    }

    /// A cool machine at full clock is not throttling — the references must not manufacture one.
    func testACoolMachineIsNotThrottling() throws {
        var s = hotSnapshot()
        s.thermal.pressure = .nominal
        s.temperature.cpuCelsius = 55
        s.temperature.gpuCelsius = 50
        s.temperature.groups = []
        s.cpu.pFreqMHz = 3228
        let m = try served(s)
        let (r, topo) = m.toDashboardSnapshot()
        XCTAssertFalse(MetricsEngine.cpuThrottling(latest: r, topology: topo))
        XCTAssertFalse(MetricsEngine.gpuThrottling(latest: r, gpuClockPeakMHz: m.apple?.gpuClockPeakMHz ?? 0))
    }

    // MARK: - Old agents and unknown values

    /// An agent from before this change sends no thermal block and no tables. It must still
    /// decode, must NOT read as "nominal", and must not grow a fake ceiling from its current clock.
    func testAnOldAgentDecodesAndClaimsNothing() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"macOS 26.6","kind":"mac","agentVersion":"1.1.0","ts":0,
         "cpu":{"cores":10,"usagePercent":40,"loadAvg1":2,"pUsagePercent":90,"pFreqMHz":2064,
                "eCores":2,"pCores":8},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1}}
        """
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        XCTAssertNil(m.thermal)
        let (s, topo) = m.toDashboardSnapshot()
        XCTAssertEqual(s.thermal.pressure, .unknown, "an unreported pressure is unknown, not nominal")
        XCTAssertTrue(topo.pFreqsMHz.isEmpty, "the current clock is not a DVFS table")
        XCTAssertFalse(MetricsEngine.cpuThrottling(latest: s, topology: topo))
    }

    /// ⚠️ A String enum throws on a value it does not know, and a throw here takes the whole
    /// machine offline in the viewer (#33's shape). A newer macOS pressure level or sensor category
    /// must degrade to "unknown" / "other" and leave everything else on the page.
    func testUnknownPressureAndCategoryDegradeInsteadOfFailing() throws {
        let json = """
        {"machineId":"m","hostname":"h","os":"macOS 28.0","kind":"mac","agentVersion":"9.0","ts":0,
         "cpu":{"cores":10,"usagePercent":40,"loadAvg1":2},
         "memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},
         "thermal":{"pressure":"molten","cpuCelsius":61,
                    "sensors":[{"category":"photonic","sensors":[{"rawName":"Tx","name":"X","celsius":40}]}]}}
        """
        let m = try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
        let (s, _) = m.toDashboardSnapshot()
        XCTAssertEqual(s.thermal.pressure, .unknown)
        XCTAssertEqual(s.temperature.groups.first?.category, .other)
        XCTAssertEqual(s.temperature.cpuCelsius, 61)
    }
}
