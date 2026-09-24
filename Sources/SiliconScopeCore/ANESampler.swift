//
//  File:      ANESampler.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads Neural Engine activity sudolessly from IOReport "SoC Stats" › "Cluster Power
//             States": two snapshots `interval` apart, ACT residency ÷ total per ANE cluster.
//             See ANESample for what the number means and why it exists.
//  Notes:     Fails to construct (nil) on a machine with no ANE cluster channel, and returns nil
//             from `sample` when the channels do not carry an "ACT" state — a shape it has not seen
//             is reported as unknown rather than guessed at. Channel names go through
//             IOReportNaming so a chip-id token ("DIE0 ANE0") still resolves.
//
import Foundation
import CIOReport

public final class ANESampler {
    private let subscription: IOReportSubscriptionRef
    private let subscribedChannels: CFMutableDictionary

    static let group = "SoC Stats"
    static let subgroup = "Cluster Power States"

    public init?() {
        guard let channels = IOReportCopyChannelsInGroup(Self.group as CFString, Self.subgroup as CFString, 0, 0, 0)?
            .takeRetainedValue()
        else {
            return nil
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, channels, &subbed, 0, nil),
              let subscribed = subbed?.takeRetainedValue()
        else {
            return nil
        }
        self.subscription = sub
        self.subscribedChannels = subscribed
    }

    /// ANE activity over `interval` seconds, or nil when no ANE cluster reports an ACT state.
    public func sample(interval: TimeInterval = 0.2) -> ANESample? {
        let first = IOReportCreateSamples(subscription, subscribedChannels, nil)
        Thread.sleep(forTimeInterval: interval)
        let second = IOReportCreateSamples(subscription, subscribedChannels, nil)
        guard let a = first?.takeRetainedValue(),
              let b = second?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue()
        else {
            return nil
        }

        var clusters: [(name: String, states: [(String, Double)])] = []
        IOReportIterate(delta) { channel in
            guard IOReportChannelGetFormat(channel) == kKtopIOReportFormatState,
                  let nameRef = IOReportChannelGetChannelName(channel)?.takeUnretainedValue(),
                  IOReportNaming.hasUnitPrefix(nameRef as String, "ANE")
            else {
                return Int32(kKtopIOReportIterOk)
            }
            var states: [(String, Double)] = []
            for i in 0..<IOReportStateGetCount(channel) {
                let name = (IOReportStateGetNameForIndex(channel, Int32(i))?.takeUnretainedValue() as String?) ?? ""
                states.append((name, Double(IOReportStateGetResidency(channel, Int32(i)))))
            }
            clusters.append((nameRef as String, states))
            return Int32(kKtopIOReportIterOk)
        }
        return Self.activity(clusters.sorted { $0.name < $1.name }.map(\.states))
    }

    /// Active share per cluster from its (state name, residency) pairs. Pure, for testing.
    /// nil when no cluster carries an "ACT" state — an unfamiliar shape is not a reading.
    static func activity(_ clusters: [[(String, Double)]]) -> ANESample? {
        var fractions: [Double] = []
        for states in clusters {
            guard states.contains(where: { $0.0 == "ACT" }) else { continue }
            let total = states.reduce(0) { $0 + $1.1 }
            let active = states.filter { $0.0 == "ACT" }.reduce(0) { $0 + $1.1 }
            fractions.append(total > 0 ? active / total : 0)
        }
        guard !fractions.isEmpty else { return nil }
        return ANESample(activeFraction: fractions.max() ?? 0, clusters: fractions)
    }
}
