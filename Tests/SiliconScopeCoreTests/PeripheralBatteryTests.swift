//
//  File:      PeripheralBatteryTests.swift
//  Created:   2026-06-22
//  Updated:   2026-06-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins PeripheralBatterySampler.kind() — the pure HID-usage / class-name / Product
//             classifier that labels accessory batteries. Trackpads use a vendor HID usage page,
//             so the class-name fallback is what catches them; that path is easy to break.
//
import XCTest
@testable import SiliconScopeCore

final class PeripheralBatteryTests: XCTestCase {

    func testKindByHIDUsage() {
        // Generic Desktop page (1): usage 2 = mouse, usage 6 = keyboard.
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 2, usagePage: 1, className: "", product: ""), .mouse)
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 6, usagePage: 1, className: "", product: ""), .keyboard)
    }

    func testKindByClassName() {
        // Trackpads report a vendor usage page (0xFF00), so the class name must catch them.
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 11, usagePage: 65280,
                                                     className: "BNBTrackpadDevice", product: ""), .trackpad)
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 0, usagePage: 0,
                                                     className: "AppleBluetoothHIDKeyboard", product: ""), .keyboard)
    }

    func testKindByProduct() {
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 0, usagePage: 0, className: "", product: "Magic Mouse"), .mouse)
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 0, usagePage: 0, className: "", product: "AirPods Pro"), .headphones)
    }

    func testKindUnknownFallsBackToOther() {
        XCTAssertEqual(PeripheralBatterySampler.kind(usage: 0, usagePage: 0, className: "SomeDongle", product: ""), .other)
    }

    func testDefaultName() {
        XCTAssertEqual(PeripheralKind.mouse.defaultName, "Mouse")
        XCTAssertEqual(PeripheralKind.trackpad.defaultName, "Trackpad")
    }
}
