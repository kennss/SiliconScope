//
//  File:      DefaultEmpty.swift
//  Created:   2026-07-23
//  Updated:   2026-07-23
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Property wrapper for wire-schema arrays: decodes `null` or an absent key as `[]`
//             instead of throwing. Encoding is unchanged (always a real array).
//  Notes:     Why this exists (issue #31 → #33): Go marshals a NIL SLICE AS `null`, so an agent on
//             a machine with no NVIDIA GPU sent `"gpus": null` — and a non-optional `[FleetGPU]`
//             rejected it with `valueNotFound`, taking that whole machine offline in the viewer.
//             Every GPU-less Linux box (Raspberry Pi, CPU-only server, VM) hit it.
//             The VIEWER has to be the tolerant side: it auto-updates via Sparkle, while agents in
//             the field do not — so tolerating `null` here fixes machines running the old agent
//             without anyone touching them. Applied to every array in the schema, not just `gpus`,
//             so the next nil slice can't reintroduce the bug.
//
import Foundation

@propertyWrapper
public struct DefaultEmpty<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element] = []) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = (try? c.decode([Element].self)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

public extension KeyedDecodingContainer {
    /// The wrapper's own `init(from:)` only sees an explicit `null`; a MISSING key would still throw
    /// `keyNotFound` before it runs. This overload covers both — an older agent that omits a field
    /// decodes as empty rather than failing the whole payload.
    func decode<T>(_ type: DefaultEmpty<T>.Type, forKey key: Key) throws -> DefaultEmpty<T> {
        try decodeIfPresent(type, forKey: key) ?? DefaultEmpty()
    }
}
