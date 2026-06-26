//
//  File:      Battery.swift
//  Created:   2026-06-08
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Battery charge/charging state (IOPowerSources) plus health/cycles/condition
//             read sudolessly from the AppleSmartBattery IORegistry entry. Stateless.
//  Notes:     hasBattery is false on desktops (Mac mini/Studio). percent = current / max
//             capacity. health = AppleRawMaxCapacity / DesignCapacity. condition is derived
//             from PermanentFailureStatus + health. Battery temperature is reported
//             separately via the temperature sensors.
//
import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Sendable, Equatable, Codable {
    public var hasBattery: Bool = false
    public var percent: Double = 0
    public var isCharging: Bool = false     // actively charging
    public var isPluggedIn: Bool = false    // on AC power
    public var isCharged: Bool = false      // full and on AC
    public var cycleCount: Int = 0
    public var healthPercent: Double = 0    // max / design capacity
    public var maxCapacity: Int = 0         // mAh (current full-charge capacity)
    public var designCapacity: Int = 0      // mAh (factory)
    public var condition: String = ""       // "Normal" / "Service Recommended"

    public init() {}

    /// One-word charge state for display ("Charging" / "Not Charging" / "On Battery").
    public var stateLabel: String {
        if !hasBattery { return "No Battery" }
        if isCharged { return "Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Not Charging" }
        return "On Battery"
    }
}

public final class BatterySampler {
    public init() {}

    public func sample() -> BatteryInfo {
        var info = BatteryInfo()

        // Charge level + charging/plugged/charged state via IOPowerSources.
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                guard let current = d[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }

                info.hasBattery = true
                info.percent = Double(current) / Double(maximum) * 100
                info.isPluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                info.isCharging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                info.isCharged = (d[kIOPSIsChargedKey] as? Bool) ?? false
            }
        }

        // Health / cycle count / condition from AppleSmartBattery (sudoless IORegistry read).
        if info.hasBattery, let props = Self.smartBatteryProperties() {
            info.cycleCount = props["CycleCount"] as? Int ?? 0
            info.designCapacity = props["DesignCapacity"] as? Int ?? 0
            // Health = full-charge / design capacity. Prefer NominalChargeCapacity — the same
            // value macOS Settings uses for "Maximum Capacity" — then the raw max. (MaxCapacity
            // is normalized to 100 on Apple Silicon, so it's useless for health.)
            info.maxCapacity = props["NominalChargeCapacity"] as? Int
                ?? props["AppleRawMaxCapacity"] as? Int
                ?? props["MaxCapacity"] as? Int ?? 0
            info.healthPercent = Self.healthPercent(maxCapacity: info.maxCapacity,
                                                    designCapacity: info.designCapacity)
            let failed = (props["PermanentFailureStatus"] as? Int ?? 0) != 0
            info.condition = Self.condition(healthPercent: info.healthPercent, permanentFailure: failed)
        }
        return info
    }

    /// Battery health = full-charge / design capacity, clamped to 100%. Pure, so the
    /// capacity formula is unit-tested. Returns 0 when capacities are unknown.
    static func healthPercent(maxCapacity: Int, designCapacity: Int) -> Double {
        guard designCapacity > 0, maxCapacity > 0 else { return 0 }
        return min(100, Double(maxCapacity) / Double(designCapacity) * 100)
    }

    /// Condition string from health + permanent-failure flag (matches macOS wording).
    static func condition(healthPercent: Double, permanentFailure: Bool) -> String {
        (permanentFailure || (healthPercent > 0 && healthPercent < 80))
            ? "Service Recommended" : "Normal"
    }

    /// Copies the AppleSmartBattery IORegistry properties, or nil on desktops / failure.
    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }
}
