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

    /// The header's single power figure, and the label and tooltip that say what it is.
    ///
    /// The SoC while its rails are live. Where they are not (macOS 27, #65) the SoC total is unknown
    /// or a half-hour average — a header is a glance, and neither describes the present — so the
    /// figure becomes the whole Mac's draw, measured by the SMC and LABELLED "system", because it
    /// includes the display and everything else and must never read as the SoC. Only when that is
    /// unavailable too does the header fall back to saying what is known about the SoC.
    var headerFigure: (label: String?, value: String, help: String?) {
        if railsLive { return (nil, text(socWatts), nil) }
        if let system = systemWatts {
            return ("system", String(format: "%.1f W", system),
                    "The whole Mac's power draw, measured by the SMC — display and everything else included. "
                    + "Shown because macOS updates the SoC's own energy counters only every several minutes here, "
                    + "so the SoC figure isn't current.")
        }
        return (basisNote, text(socWatts), basisExplanation)
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

extension SystemSnapshot {
    /// 0…1 for an ANE bar: the engine's MEASURED residency where the machine has it, otherwise its
    /// power against the observed peak (the only evidence there was before residency was found).
    /// One rule for every surface — the menu bar and the dashboard must not disagree on how busy
    /// the ANE is.
    func aneFraction(peakWatts: Double) -> Double {
        if let a = ane { return a.activeFraction }
        return min(1, power.aneWatts / max(peakWatts, 0.1))
    }

    /// The ANE's ACTIVITY as text, for the rows that say what the engine is doing.
    func aneText(format: String = "%.1f W") -> String {
        ANEText.activity(ane: ane, bandwidth: bandwidth, power: power, format: format)
    }

    /// For a menu-bar glyph, where a single short value fits: the watts when they are a reading,
    /// otherwise the measured activity — on macOS 27 the watts can be unknown for an hour (#65)
    /// while the engine's activity is known every second.
    var aneGlyphText: String {
        if power.railsKnown { return power.text(power.aneWatts) }
        return ane.map { String(format: "%.0f%%", $0.activeFraction * 100) } ?? "—"
    }
}

extension MetricsEngine.History {
    /// The ANE trend on a 0…1 axis: residency where measured, else power scaled to its peak.
    func aneSeries(measured: Bool, peakWatts: Double) -> [Double] {
        measured ? aneActive : ane.map { $0.scaledToCeiling(max(peakWatts, 0.1)) }
    }
}

/// How the Neural Engine's activity reads, wherever a row describes what the engine is DOING.
///
/// Measured residency and the engine's memory traffic — "100% · 19 GB/s". Both are read every
/// second on every macOS that exposes them. Residency alone saturates the moment a model runs;
/// the traffic is what says how hard it is working. The engine's watts belong to the power views
/// (the SoC total, the power breakdown), because on macOS 27 they can be unknown for an hour and
/// then a half-hour average (#65) — no description of the present.
///
/// Where a measurement is missing it steps back rather than inventing one: residency with watts
/// where the ANE lane is not split out, watts alone where there is no residency at all.
enum ANEText {
    static func activity(ane: ANESample?, bandwidth: BandwidthSample, power: PowerSample,
                         format: String = "%.1f W") -> String {
        let watts = power.text(power.aneWatts, format: format)
        guard let a = ane else { return watts }
        let pct = String(format: "%.0f%%", a.activeFraction * 100)
        guard let gbs = bandwidth.aneGBs else { return pct + " · " + watts }
        return pct + " · " + String(format: gbs < 10 ? "%.1f GB/s" : "%.0f GB/s", gbs)
    }
}
