//
//  File:      ThrottleDetectionTests.swift
//  Created:   2026-07-29
//  Updated:   2026-07-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the difference between a machine that is throttled and one that is merely
//             cooling down. Both readings were captured on an M1 Max: after an LLM run ended, the
//             dashboard outlined BOTH the CPU and GPU cards red while nothing was running.
//  Notes:     The numbers here are the real ones from each case, not invented — that is the point.
//             Utilisation cannot separate them (63 % vs 97 % on the GPU is suggestive, but 37 % vs
//             41 % on the CPU is not); temperature separates them cleanly at 60 °C vs 93 °C,
//             because thermal throttling requires a hot die and not merely a recently hot one.
//
import XCTest
@testable import SiliconScopeCore

final class ThrottleDetectionTests: XCTestCase {

    /// The machine a few seconds after a heavy LLM run: fans still at 3400 rpm, so macOS still
    /// reports `fair` pressure, while every engine has dropped to its minimum clock because nothing
    /// is asking for performance any more.
    private func coolingDown() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.thermal.pressure = .fair
        s.temperature.cpuCelsius = 59
        s.temperature.cpuMaxCelsius = 61
        s.temperature.gpuCelsius = 57
        s.gpu.usage = 0.63          // the counter stays high; the silicon is idle
        s.gpu.freqMHz = 389         // minimum clock
        s.power.gpuWatts = 0.4      // …and 0.4 W proves it
        s.cpu.pUsage = 0.37
        s.cpu.pFreqMHz = 2232
        return s
    }

    /// The same machine mid-run: LM Studio generating on a 12B model.
    private func underLoad() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.thermal.pressure = .fair
        s.temperature.cpuCelsius = 93
        s.temperature.cpuMaxCelsius = 96
        s.temperature.gpuCelsius = 100
        s.gpu.usage = 0.97
        s.gpu.freqMHz = 1284
        s.power.gpuWatts = 39.4
        s.cpu.pUsage = 0.41
        s.cpu.pFreqMHz = 2272
        return s
    }

    private let topology = CPUTopology(
        chipName: "Apple M1 Max", eCoreCount: 2, pCoreCount: 8,
        eFreqsMHz: [600, 2064], pFreqsMHz: [600, 3228], gpuFreqsMHz: [],
        pLevelName: "Performance", eLevelName: "Efficiency")

    /// The bug: an idle machine wearing two red cards.
    func testCoolingDownIsNotThrottling() {
        let s = coolingDown()
        XCTAssertFalse(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 1284),
                       "a GPU at 0.4 W on its minimum clock is idle, not held back")
        XCTAssertFalse(MetricsEngine.cpuThrottling(latest: s, topology: topology),
                       "37 % busy at 60 °C is ordinary DVFS, not a thermal cap")
    }

    /// …and the detector must still fire when it is real, or the fix would just be a mute.
    func testGenuineThrottleIsStillDetected() {
        let s = underLoad()
        XCTAssertTrue(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 1600))
        XCTAssertTrue(MetricsEngine.cpuThrottling(latest: s, topology: topology))
    }

    /// Utilisation alone cannot tell the two apart — which is why it is not what decides.
    func testUtilisationDoesNotSeparateTheCases() {
        XCTAssertLessThan(abs(coolingDown().cpu.pUsage - underLoad().cpu.pUsage), 0.10,
                          "37 % vs 41 % — any usage threshold would catch both or neither")
    }

    /// A hot die that is genuinely idle is still not throttled: heat is necessary, not sufficient.
    func testHotButIdleIsNotThrottling() {
        var s = underLoad()
        s.gpu.usage = 0.02
        s.power.gpuWatts = 0.3
        s.cpu.pUsage = 0.01
        XCTAssertFalse(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 1600))
        XCTAssertFalse(MetricsEngine.cpuThrottling(latest: s, topology: topology))
    }

    /// Nominal pressure means the OS sees no thermal limit at all — nothing else can override that.
    func testNominalPressureIsNeverThrottling() {
        var s = underLoad()
        s.thermal.pressure = .nominal
        XCTAssertFalse(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 1600))
        XCTAssertFalse(MetricsEngine.cpuThrottling(latest: s, topology: topology))
    }

    /// A machine that reports no GPU sensor must still be able to report a GPU throttle — the die
    /// temperature is evidence of heat even when the GPU's own probe is missing.
    func testGPUThrottleFallsBackToDieTemperature() {
        var s = underLoad()
        s.temperature.gpuCelsius = 0
        XCTAssertTrue(MetricsEngine.gpuThrottling(latest: s, gpuClockPeakMHz: 1600))
    }

    /// The colour bands and the throttle floor are the same definition of "hot".
    func testThermalReferenceIsShared() {
        XCTAssertEqual(MetricsEngine.Thermal.warnCelsius, 80)
        XCTAssertLessThan(MetricsEngine.Thermal.warnCelsius, MetricsEngine.Thermal.criticalCelsius)
    }
}
