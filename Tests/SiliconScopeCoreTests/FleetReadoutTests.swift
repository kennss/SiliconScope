//
//  File:      FleetReadoutTests.swift
//  Created:   2026-10-18
//  Updated:   2026-10-18
//  Developer: SiliconScope contributors
//  Overview:  Locks in the wording rules for a remote GPU's watts and temperature: unknown values
//             are absent, a live 0 W is a reading, averaged watts are marked, Linux passes through.
//  Notes:     Machines are built by hand, shaped like what the Mac encoder and the Go agent send.
//
import XCTest
@testable import SiliconScopeCore

final class FleetReadoutTests: XCTestCase {
    private func gpu(watts: Double, temp: Double) -> FleetGPU {
        FleetGPU(index: 0, name: "g", driver: "d", vramTotalBytes: 1, vramUsedBytes: 0,
                 utilizationPercent: 0, temperatureC: temp, powerDrawW: watts, powerLimitW: 0, processes: [])
    }

    private func apple(window: Double?, gpuWindow: Double? = nil) -> FleetApple {
        FleetApple(chip: "M", aneWatts: 0, anePeakWatts: 1, mediaGBs: 0, mediaPeakGBs: 1, socWatts: 0,
                   power: FleetPower(cpuWatts: 0, eCpuWatts: 0, pCpuWatts: 0, gpuWatts: 0, aneWatts: 0,
                                     dramWatts: 0, windowSeconds: window, gpuWindowSeconds: gpuWindow),
                   bandwidth: FleetBandwidth(cpuGBs: 0, gpuGBs: 0, mediaGBs: 0, otherGBs: 0,
                                             totalGBs: 0, isEstimated: false),
                   fanRPMs: [])
    }

    func testMacWattsPendingIsUnknown() {
        XCTAssertNil(FleetReadout.gpuWatts(gpu(watts: 0, temp: 40), apple: apple(window: 0)))
    }

    func testMacGPUOwnClockOverridesPendingRails() {
        XCTAssertEqual(FleetReadout.gpuWatts(gpu(watts: 0.3, temp: 40), apple: apple(window: 0, gpuWindow: 2)), "0W")
    }

    func testMacLiveZeroWattsIsAReading() {
        XCTAssertEqual(FleetReadout.gpuWatts(gpu(watts: 0, temp: 40), apple: apple(window: nil)), "0W")
    }

    func testMacAveragedWattsAreMarked() {
        XCTAssertEqual(FleetReadout.gpuWatts(gpu(watts: 5, temp: 40), apple: apple(window: 1800)), "~5W")
    }

    func testMacZeroTemperatureIsAbsent() {
        XCTAssertNil(FleetReadout.gpuTemperature(gpu(watts: 1, temp: 0), apple: apple(window: nil)))
        XCTAssertEqual(FleetReadout.gpuTemperature(gpu(watts: 1, temp: 41.6), apple: apple(window: nil)), "41°C")
    }

    func testLinuxZerosPassThrough() {
        XCTAssertEqual(FleetReadout.gpuWatts(gpu(watts: 0, temp: 0), apple: nil), "0W")
        XCTAssertEqual(FleetReadout.gpuTemperature(gpu(watts: 0, temp: 0), apple: nil), "0°C")
    }
}
