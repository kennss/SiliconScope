//
//  File:      ModelBudgetText.swift
//  Created:   2026-11-20
//  Updated:   2026-11-20
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The one wording of the model budget — "~16B in 11 GB usable" and the tooltip that
//             shows the subtraction behind it — shared by the dashboard's AI Runtime card and the
//             menu-bar popover, so the same reading is never phrased two ways.
//  Notes:     UI layer (strings), not Core: MemoryBudget stays a value type. The reserve rule in
//             the tooltip is read from MemoryBudget's own constants, so the explanation cannot
//             drift from the arithmetic.
//
import Foundation
import SiliconScopeCore

extension MemoryBudget {
    private static let bytesPerGB = 1_073_741_824.0

    /// The line: the largest model that fits now, and the memory it was sized against. With a
    /// model already resident, also what fits once it is unloaded.
    ///
    /// The basis is printed: "~12B" alone read as the machine's limit ("64 GB and only 12B?"),
    /// when it is what fits in the memory usable right now. "usable", not "unused" or "free": it is
    /// the Memory card's Free less what is kept back for macOS, and the tooltip shows that
    /// subtraction. The quantisation the sizes assume (Q4_K_M) is there too.
    func summary(residentModel: String) -> String {
        let nowB = fitsNow.first.map { String(format: "%.0fB", $0.maxParamsBillions) } ?? "—"
        // A resident model taking meaningful RSS ⇒ both scenarios; otherwise one value.
        if loadableBytes > headroomNowBytes + (1 << 30), let load = fitsLoadable.first {
            return "+\(nowB) alongside · ~\(String(format: "%.0fB", load.maxParamsBillions)) if you unload \(residentModel)"
        }
        return "~\(nowB) in \(String(format: "%.0f", headroomNowGB)) GB usable"
    }

    /// The subtraction behind "GB usable", in the same numbers the Memory card shows.
    var basisHelp: String {
        let free = Double(totalBytes > usedBytes ? totalBytes - usedBytes : 0) / Self.bytesPerGB
        let kept = Double(reservedBytes) / Self.bytesPerGB
        return String(format: "Free %.1f GB − %.1f GB kept for macOS (%.0f%% of RAM, at least %.0f GB) = %.1f GB usable. Free is everything not used by apps, wired or compressed; file cache counts as free, as in Activity Monitor, because macOS gives it back on demand. The model figure is the largest that fits there at Q4_K_M quantisation, with a %d-token context and runtime overhead. With a model loaded, the second figure is what fits once it is unloaded.",
                      free, kept, Self.defaultReserveFraction * 100,
                      Double(Self.defaultReserveFloorBytes) / Self.bytesPerGB,
                      headroomNowGB, contextTokens)
    }

    /// What to call the model that is resident: the runtime's own name for it when its API says,
    /// otherwise the runtime's.
    static func residentModelName(api: RuntimeAPISample, runtime: AIRuntimeSample) -> String {
        if let name = api.primaryModel?.name { return name }
        if let kind = runtime.primaryKind { return "\(kind.displayName) model" }
        return "current model"
    }
}
