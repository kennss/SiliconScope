//
//  File:      RuntimeBeaconReader.swift
//  Created:   2026-07-15
//  Updated:   2026-10-01
//  Developer: Vincent Gourbin
//  Overview:  Reads opt-in "AI runtime beacons" — small JSON manifests that inference
//             frameworks write to ~/Library/Application Support/ai-runtime-beacons/
//             while a heavy operation (generation, training, model load) is running,
//             and delete when it ends. Complements AIRuntimeKind.match for runtimes
//             that are statically linked into a host app, where path/basename/argv
//             carry no signature at all (e.g. a SwiftPM MLX framework inside "MyApp").
//  Notes:     Manifests are named "<pid>-<id>.json". A manifest whose pid is dead is
//             a leftover from a force-killed process: it is deleted on sight, so a
//             beacon can never outlive its process (kill(pid, 0) + ESRCH probe, no
//             signal sent). Multiple manifests per pid are legal (nested operations);
//             the freshest updatedAt wins. 100% sudoless, no network.
//
import Foundation

/// One decoded beacon manifest (schema version 1). Producer-agnostic: any local
/// inference framework can adopt the convention. Reference producer:
/// ltx-video-swift-mlx's RuntimeBeacon.
public struct BeaconManifest: Sendable, Equatable, Codable {
    public let version: Int
    public let pid: Int32
    public let runtime: String        // stable identifier, e.g. "ltx-video-swift-mlx"
    public let displayName: String?   // human name, e.g. "LTX-Video"
    public let task: String?          // e.g. "generate", "train", "load-models"
    public let model: String?         // e.g. "distilled"
    public let phase: String?         // e.g. "denoising"
    public let step: Int?
    public let totalSteps: Int?
    public let startedAt: Date?
    public let updatedAt: Date?

    public init(version: Int, pid: Int32, runtime: String, displayName: String? = nil,
                task: String? = nil, model: String? = nil, phase: String? = nil,
                step: Int? = nil, totalSteps: Int? = nil,
                startedAt: Date? = nil, updatedAt: Date? = nil) {
        self.version = version
        self.pid = pid
        self.runtime = runtime
        self.displayName = displayName
        self.task = task
        self.model = model
        self.phase = phase
        self.step = step
        self.totalSteps = totalSteps
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public final class RuntimeBeaconReader {
    /// Shared, producer-agnostic manifest directory.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai-runtime-beacons", isDirectory: true)
    }

    private let directory: URL
    private let decoder: JSONDecoder

    public init(directory: URL = RuntimeBeaconReader.defaultDirectory) {
        self.directory = directory
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Snapshot of all live beacons, keyed by pid (freshest updatedAt wins when a
    /// process runs nested operations). Dead-pid manifests are deleted, undecodable
    /// files are skipped; a missing directory just returns [:] — beacons are
    /// strictly opt-in and usually absent.
    public func read() -> [pid_t: BeaconManifest] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [:] }

        var beacons: [pid_t: BeaconManifest] = [:]
        for url in entries where url.pathExtension == "json" {
            // pid comes from the filename so dead-pid GC never needs to parse JSON.
            guard let pidToken = url.lastPathComponent.split(separator: "-").first,
                  let pid = pid_t(pidToken) else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(BeaconManifest.self, from: data),
                  manifest.pid == pid else { continue }
            if let existing = beacons[pid],
               (existing.updatedAt ?? .distantPast) >= (manifest.updatedAt ?? .distantPast) {
                continue
            }
            beacons[pid] = manifest
        }
        return beacons
    }
}
