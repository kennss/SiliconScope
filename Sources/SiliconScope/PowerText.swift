//
//  File:      PowerText.swift
//  Created:   2026-09-24
//  Updated:   2026-09-24
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The one way a domain wattage becomes text. Knows the three states a reading can be
//             in since macOS 27 (#65): live, an average over minutes, or not known yet.
//  Notes:     Every "%.1f W" for a CPU / GPU / ANE / DRAM / SoC figure goes through here. Formatting
//             them inline is how 0.0 W reached the screen for a machine drawing tens of watts: the
//             zero in an unknown PowerSample is a placeholder, and only this layer can tell.
//
import Foundation
import SiliconScopeCore

extension PowerSample {
    /// A domain wattage for display: the number when it is a reading, "—" when it is not.
    /// An average over a span longer than the tick is prefixed "~" — the compact mark for surfaces
    /// with no room to say more; `basisNote` spells it out where there is.
    func text(_ watts: Double, format: String = "%.1f W") -> String {
        guard railsKnown else { return "—" }
        return (railsAveraged ? "~" : "") + String(format: format, watts)
    }

    /// The GPU wattage for display, judged on the GPU's own basis: on macOS 27 it is often live
    /// while every other rail is pending or averaged (#65).
    func gpuText(format: String = "%.1f W") -> String {
        guard gpuKnown else { return "—" }
        return (gpuAveraged ? "~" : "") + String(format: format, gpuWatts)
    }

    /// A short label for how the domain wattages were measured, or nil when they are live. Short
    /// because it sits beside a number in a header; `basisExplanation` is the long form.
    var basisNote: String? {
        if !railsKnown { return "power pending" }
        guard let seconds = railWindowSeconds, seconds > 0 else { return nil }
        return seconds >= 90 ? String(format: "avg over %.0f min", seconds / 60)
                             : String(format: "avg over %.0f s", seconds)
    }

    /// Why the power reads the way it does, for a tooltip — nil when it is live.
    var basisExplanation: String? {
        if !railsKnown {
            return "macOS refreshes its energy counters only every several minutes here. Power appears once two refreshes have been seen."
        }
        guard railsAveraged else { return nil }
        return "macOS refreshes its energy counters only every several minutes here, so each figure is the measured average between the last two refreshes."
    }
}
