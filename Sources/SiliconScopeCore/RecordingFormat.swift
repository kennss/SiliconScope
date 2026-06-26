//
//  File:      RecordingFormat.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  On-disk format for a recorded session (.ssrec, JSONL). The first line is a
//             RecordingMeta object; every subsequent line is a RecordedFrame. Shared by the
//             writer (SessionRecorder) and the reader (SessionReader, replay). Promoted from
//             SessionRecorder's internal types so replay can decode them.
//  Notes:     `version` and `topology` are optional so Phase-1 files (which lacked both) still
//             decode — `version == nil` is treated as 1. Bump `recordingFormatVersion` only on a
//             breaking change; additive fields stay backward-compatible (optional → nil on old files).
//
import Foundation

/// Current on-disk format version written by SessionRecorder.
public let recordingFormatVersion = 1

/// First line of a `.ssrec` — session metadata.
public struct RecordingMeta: Codable, Sendable {
    public let kind: String            // always "meta"
    public let version: Int?           // nil on Phase-1 files → treat as 1
    public let app: String
    public let chip: String
    public let model: String
    public let os: String
    public let started: Date
    public let cadenceHz: Double
    public let topology: CPUTopology?  // nil on Phase-1 files

    /// Effective format version (Phase-1 files lacking the key are version 1).
    public var formatVersion: Int { version ?? 1 }

    public init(kind: String = "meta", version: Int?, app: String, chip: String, model: String,
                os: String, started: Date, cadenceHz: Double, topology: CPUTopology?) {
        self.kind = kind; self.version = version; self.app = app; self.chip = chip
        self.model = model; self.os = os; self.started = started
        self.cadenceHz = cadenceHz; self.topology = topology
    }
}

/// One recorded frame: elapsed seconds since start + the full snapshot at that instant.
public struct RecordedFrame: Codable, Sendable {
    public let t: Double
    public let snapshot: SystemSnapshot
    public init(t: Double, snapshot: SystemSnapshot) { self.t = t; self.snapshot = snapshot }
}
