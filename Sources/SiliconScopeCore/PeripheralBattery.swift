//
//  File:      PeripheralBattery.swift
//  Created:   2026-06-22
//  Updated:   2026-10-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Sudoless battery levels for connected peripherals, the way iStat Menus surfaces
//             accessory batteries in its battery dropdown. Two sources, merged:
//               1) IORegistry `BatteryPercent` — Apple Magic Mouse/Trackpad/Keyboard and any HID
//                  device that exposes it. Fast, no subprocess; read every call.
//               2) `system_profiler SPBluetoothDataType` — AirPods (Left/Right/Case) and other
//                  Bluetooth devices whose battery only macOS aggregates. Spawns a process
//                  (~0.2 s, measured) so it is cached behind a short TTL; the caller (SystemSampler)
//                  drives the real cadence (~5 s).
//  Notes:     Logitech (MX Master etc.) expose battery only over HID++ — a separate tier (see
//             NEXT_VERSION). No charging state yet (BatteryStatusFlags semantics unverified).
//             ⚠️ The app's sample() never waits for system_profiler: it starts a refresh in the
//             background and returns the last finished one (#86). The tool talks to bluetoothd,
//             and a wedged bluetoothd once meant a sampling loop stopped for good — every reading
//             in the app frozen until a restart. The refresh is bounded (BoundedCommand) so a stuck
//             one is killed and the next can start. A one-shot reader (the CLI) asks for `.fresh`.
//             Use one sampler per thread; the background refresh touches only `bluetooth`.
//
import Foundation
import IOKit
import os

public enum PeripheralKind: String, Sendable, Codable {
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

public struct PeripheralBattery: Sendable, Equatable, Identifiable, Codable {
    public var name: String
    public var kind: PeripheralKind
    public var percent: Int            // 0–100 (headline; for buds = lower of L/R)
    public var address: String         // Bluetooth address, e.g. "3c-a6-f6-c3-33-f6"
    public var leftPercent: Int?       // multi-cell devices (AirPods) only
    public var rightPercent: Int?
    public var casePercent: Int?

    public var id: String { address.isEmpty ? name : address }

    /// Per-cell breakdown for display, e.g. "L 9% · R 99% · Case 21%" (nil for single-cell).
    public var detail: String? {
        var parts: [String] = []
        if let l = leftPercent  { parts.append("L \(l)%") }
        if let r = rightPercent { parts.append("R \(r)%") }
        if let c = casePercent  { parts.append("Case \(c)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public init(name: String, kind: PeripheralKind, percent: Int, address: String,
                leftPercent: Int? = nil, rightPercent: Int? = nil, casePercent: Int? = nil) {
        self.name = name
        self.kind = kind
        self.percent = percent
        self.address = address
        self.leftPercent = leftPercent
        self.rightPercent = rightPercent
        self.casePercent = casePercent
    }
}

public final class PeripheralBatterySampler {
    /// How sample() gets the system_profiler devices (AirPods etc.).
    public enum BluetoothRead: Sendable {
        /// The last finished background refresh; starts the next one when it is due. Never blocks.
        case cached
        /// Runs system_profiler now and waits for it, up to `btTimeout`. For one-shot readers.
        case fresh
    }

    private struct BluetoothState {
        var devices: [PeripheralBattery] = []
        var lastStart: Date = .distantPast
        var refreshing = false
    }
    /// Shared with the background refresh, hence the lock.
    private let bluetooth = OSAllocatedUnfairLock(initialState: BluetoothState())
    // Throttle the ~0.2 s system_profiler spawn (AirPods L/R/Case). Accessory battery % changes
    // slowly, so 30 s is plenty; the cheap IORegistry HID scan below stays on the caller's faster
    // cadence, so new-device latency is unaffected. (Was 3 s — energy: system_profiler was the
    // heaviest background sampler; see docs/energy-optimization.md FIX 4.)
    private let btTTL: TimeInterval = 30
    /// system_profiler SPBluetoothDataType takes ~0.1–0.2 s (measured); fifty times that means
    /// bluetoothd is not answering, and the run is abandoned.
    static let btTimeout: TimeInterval = 10

    public init() {}

    /// All connected peripherals with a battery level, sorted by name. Sudoless. Merges the
    /// fast IORegistry scan with a cached system_profiler read (AirPods etc.), deduped by address.
    public func sample(bluetooth read: BluetoothRead = .cached) -> [PeripheralBattery] {
        var devices = ioRegistryDevices()
        let seen = Set(devices.map { Self.normalizedAddress($0.address) }.filter { !$0.isEmpty })
        let audio = read == .fresh ? Self.readBluetoothDevices() : bluetoothAudioDevices()
        for d in audio where !seen.contains(Self.normalizedAddress(d.address)) {
            devices.append(d)
        }
        return devices.sorted { $0.name < $1.name }
    }

    // MARK: - Source 1: IORegistry BatteryPercent (Apple HID)

    /// IOKit classes that publish `BatteryPercent` for HID peripherals (Magic Mouse/Trackpad/
    /// Keyboard on the modern class; the rest are legacy Bluetooth HID). Matching these few
    /// services replaces the old FULL IOService-plane recursive walk, which serialized every
    /// registry entry's whole property table (~3,200 entries, ~0.7 s CPU — mostly kernel/sys
    /// time — per scan ≈ 14% of a core at the 5 s cadence: the app's single largest energy
    /// cost, found in the #28 investigation). Class matching returns a handful of entries.
    private static let batteryServiceClasses = [
        "AppleDeviceManagementHIDEventService",   // modern Magic devices (+ built-in keyboard node)
        "AppleHSBluetoothDevice",                 // legacy BT HID
        "BNBMouseDevice",
        "AppleBluetoothHIDKeyboard",
    ]

    private func ioRegistryDevices() -> [PeripheralBattery] {
        var byKey: [String: PeripheralBattery] = [:]
        for cls in Self.batteryServiceClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            collectBatteryDevices(from: iterator, into: &byKey)
        }
        return Array(byKey.values)
    }

    private func collectBatteryDevices(from iterator: io_iterator_t,
                                       into byKey: inout [String: PeripheralBattery]) {
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
    }

    // MARK: - Source 2: system_profiler (AirPods L/R/Case, cached)

    /// The last finished refresh. Starts a new one in the background when `btTTL` has passed and
    /// none is running, so at most one system_profiler exists at a time.
    private func bluetoothAudioDevices() -> [PeripheralBattery] {
        let ttl = btTTL
        let start = bluetooth.withLock { s -> Bool in
            guard !s.refreshing, Date().timeIntervalSince(s.lastStart) >= ttl else { return false }
            s.refreshing = true
            s.lastStart = Date()
            return true
        }
        if start {
            let state = bluetooth
            DispatchQueue.global(qos: .utility).async {
                let devices = Self.readBluetoothDevices()
                state.withLock { $0.devices = devices; $0.refreshing = false }
            }
        }
        return bluetooth.withLock { $0.devices }
    }

    /// One bounded system_profiler run, parsed. A run that timed out yields no devices: a battery
    /// level bluetoothd could not report just now is unknown, not the one read half a minute ago.
    private static func readBluetoothDevices() -> [PeripheralBattery] {
        guard let data = BoundedCommand.run("/usr/sbin/system_profiler", ["SPBluetoothDataType"],
                                            timeout: btTimeout)
        else { return [] }
        return parseBluetoothBatteries(String(decoding: data, as: UTF8.self))
    }

    /// Parses `system_profiler SPBluetoothDataType` text into the connected devices that report a
    /// battery (single `Battery Level`, or `Left`/`Right`/`Case` for buds). Pure → unit-tested.
    /// Device-name lines are identified by indentation under "Connected:", so nested sub-headers
    /// (Services:, etc.) don't get mistaken for devices.
    static func parseBluetoothBatteries(_ text: String) -> [PeripheralBattery] {
        var result: [PeripheralBattery] = []
        var inConnected = false
        var deviceIndent = -1
        var name: String?
        var address = "", minorType = ""
        var single: Int?, left: Int?, right: Int?, casePct: Int?

        func flush() {
            defer { name = nil; address = ""; minorType = ""; single = nil; left = nil; right = nil; casePct = nil }
            guard let n = name, single != nil || left != nil || right != nil || casePct != nil else { return }
            let pct = single ?? [left, right].compactMap { $0 }.min() ?? casePct ?? 0
            result.append(PeripheralBattery(
                name: n, kind: kind(usage: 0, usagePage: 0, className: minorType, product: n),
                percent: pct, address: address,
                leftPercent: left, rightPercent: right, casePercent: casePct))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count

            if trimmed == "Connected:" { inConnected = true; deviceIndent = -1; continue }
            if trimmed == "Not Connected:" { flush(); inConnected = false; continue }
            guard inConnected else { continue }

            let isHeader = trimmed.hasSuffix(":") && !trimmed.dropLast().contains(":")
            if isHeader, deviceIndent == -1 { deviceIndent = indent }
            if isHeader, indent == deviceIndent { flush(); name = String(trimmed.dropLast()); continue }
            if deviceIndent != -1, indent < deviceIndent { flush(); inConnected = false; continue }

            if let v = batteryValue(trimmed, "Left Battery Level")  { left = v }
            else if let v = batteryValue(trimmed, "Right Battery Level") { right = v }
            else if let v = batteryValue(trimmed, "Case Battery Level")  { casePct = v }
            else if let v = batteryValue(trimmed, "Battery Level")       { single = v }
            else if trimmed.hasPrefix("Address:")    { address = String(trimmed.dropFirst("Address:".count)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("Minor Type:") { minorType = String(trimmed.dropFirst("Minor Type:".count)).trimmingCharacters(in: .whitespaces) }
        }
        flush()
        return result
    }

    /// Extracts the integer percent from a "<label>: NN%" line, or nil if the label doesn't match.
    static func batteryValue(_ line: String, _ label: String) -> Int? {
        guard line.hasPrefix(label) else { return nil }
        let rest = line.dropFirst(label.count).drop { $0 == " " || $0 == ":" }
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Classification

    /// Classifies a device by HID usage (Generic Desktop page) with an IOKit-class / Product /
    /// minor-type fallback (trackpads use a vendor usage page, so the name is what catches them).
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

    /// Lowercased hex-only form of a BT address for cross-source dedup
    /// ("3C:A6:..." and "3c-a6-..." → "3ca6...").
    static func normalizedAddress(_ address: String) -> String {
        address.lowercased().filter { $0.isHexDigit }
    }
}
