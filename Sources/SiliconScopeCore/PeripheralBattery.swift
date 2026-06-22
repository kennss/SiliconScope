//
//  File:      PeripheralBattery.swift
//  Created:   2026-06-22
//  Updated:   2026-06-22
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Sudoless battery levels for connected input peripherals (Apple Magic Mouse /
//             Trackpad / Keyboard and other HID devices that expose `BatteryPercent`). Scans
//             the IORegistry for any entry carrying a `BatteryPercent` property, the way iStat
//             Menus surfaces accessory batteries in its battery dropdown.
//  Notes:     Apple Bluetooth HID devices put `BatteryPercent` (0–100) on the top device node
//             (e.g. AppleBluetoothHIDKeyboard, BNBTrackpadDevice) along with DeviceAddress,
//             Product (often empty), PrimaryUsage/Page and VendorID. Device kind is inferred
//             from HID usage + IOKit class name. Logitech (MX Master etc.) and most third-party
//             keyboards do NOT expose this — they need HID++ / BLE handling (see NEXT_VERSION).
//             AirPods report via `system_profiler` instead, not here. No charging state yet
//             (BatteryStatusFlags semantics unverified — omitted rather than shown wrong).
//
import Foundation
import IOKit

public enum PeripheralKind: String, Sendable {
    case mouse, keyboard, trackpad, headphones, gamepad, other

    /// Fallback label when the device exposes no Product string.
    public var defaultName: String {
        switch self {
        case .mouse:      return "Mouse"
        case .keyboard:   return "Keyboard"
        case .trackpad:   return "Trackpad"
        case .headphones: return "Headphones"
        case .gamepad:    return "Game Controller"
        case .other:      return "Device"
        }
    }
}

public struct PeripheralBattery: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: PeripheralKind
    public var percent: Int           // 0–100
    public var address: String        // Bluetooth address, e.g. "3c-a6-f6-c3-33-f6"

    public var id: String { address.isEmpty ? name : address }

    public init(name: String, kind: PeripheralKind, percent: Int, address: String) {
        self.name = name
        self.kind = kind
        self.percent = percent
        self.address = address
    }
}

public final class PeripheralBatterySampler {
    public init() {}

    /// Connected peripherals exposing a battery level, sorted by name. Sudoless. Battery moves
    /// slowly — call this on a slow cadence (e.g. ~30–60 s), not every UI tick.
    public func sample() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively),
                                       &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var byKey: [String: PeripheralBattery] = [:]   // dedup by address/name
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let percent = props["BatteryPercent"] as? Int, (1...100).contains(percent)
            else { continue }

            let address = (props["DeviceAddress"] as? String) ?? (props["SerialNumber"] as? String) ?? ""
            let product = (props["Product"] as? String) ?? ""
            let usage = props["PrimaryUsage"] as? Int ?? 0
            let usagePage = props["PrimaryUsagePage"] as? Int ?? 0
            let kind = Self.kind(usage: usage, usagePage: usagePage,
                                 className: Self.className(of: entry), product: product)
            let name = product.isEmpty ? kind.defaultName : product
            let key = address.isEmpty ? name : address
            if byKey[key] == nil {
                byKey[key] = PeripheralBattery(name: name, kind: kind, percent: percent, address: address)
            }
        }
        return byKey.values.sorted { $0.name < $1.name }
    }

    /// Classifies a device by HID usage (Generic Desktop page) with an IOKit-class / Product
    /// fallback (trackpads use a vendor usage page, so the class name is what catches them).
    static func kind(usage: Int, usagePage: Int, className: String, product: String) -> PeripheralKind {
        let c = className.lowercased(), p = product.lowercased()
        if c.contains("trackpad") || p.contains("trackpad") { return .trackpad }
        if c.contains("keyboard") || p.contains("keyboard") || (usagePage == 1 && usage == 6) { return .keyboard }
        if c.contains("mouse") || p.contains("mouse") || (usagePage == 1 && usage == 2) { return .mouse }
        if c.contains("headphone") || c.contains("headset") || p.contains("airpod") { return .headphones }
        if c.contains("gamecontroller") || c.contains("gamepad") { return .gamepad }
        return .other
    }

    /// IOKit class name of a registry entry (e.g. "AppleBluetoothHIDKeyboard"), or "".
    private static func className(of entry: io_registry_entry_t) -> String {
        guard let cf = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "" }
        return cf as String
    }
}
