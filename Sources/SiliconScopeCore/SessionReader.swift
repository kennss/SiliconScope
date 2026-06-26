//
//  File:      SessionReader.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Loads a .ssrec (JSONL) into a LoadedRecording for replay: parses the meta line and
//             the frame lines, validates the format version, and runs the SAME MetricsEngine the
//             live monitor uses over the frames to precompute per-frame derived scalars (peaks +
//             memory rates) — guaranteeing the replayed verdicts match what was shown live.
//  Notes:     Line-resilient: an unparseable line (e.g. a final truncated line from a crash mid-
//             write) is skipped, not fatal. v1 reads the whole file then splits (recordings are
//             user-initiated and bounded); a byte-offset index + lazy decode is the documented
//             scale path for very long recordings.
//
import Foundation

public enum SessionReader {
    public enum LoadError: Error, Equatable {
        case empty                       // file has no usable content
        case missingMeta                 // first line isn't a "meta" object
        case noFrames                    // meta present but no decodable frames
        case unsupportedVersion(Int)     // recorded by a newer SiliconScope
    }

    public static func load(_ url: URL) throws -> LoadedRecording {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw LoadError.empty }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        guard let metaData = lines.first?.data(using: .utf8),
              let meta = try? dec.decode(RecordingMeta.self, from: metaData),
              meta.kind == "meta"
        else { throw LoadError.missingMeta }
        guard meta.formatVersion <= recordingFormatVersion else {
            throw LoadError.unsupportedVersion(meta.formatVersion)
        }

        var frames: [RecordedFrame] = []
        frames.reserveCapacity(lines.count - 1)
        for line in lines.dropFirst() {
            guard let data = line.data(using: .utf8),
                  let frame = try? dec.decode(RecordedFrame.self, from: data) else { continue }
            frames.append(frame)
        }
        guard !frames.isEmpty else { throw LoadError.noFrames }

        return LoadedRecording(meta: meta, frames: frames, derived: precompute(frames, topology: meta.topology))
    }

    /// Folds the frames through a MetricsEngine once, capturing the path-dependent scalars per frame.
    private static func precompute(_ frames: [RecordedFrame], topology: CPUTopology?) -> [DerivedScalars] {
        let engine = MetricsEngine(topology: topology)
        var out: [DerivedScalars] = []
        out.reserveCapacity(frames.count)
        var prevT = frames.first?.t ?? 0
        for (i, f) in frames.enumerated() {
            let dt = i == 0 ? 0 : f.t - prevT
            prevT = f.t
            engine.ingest(f.snapshot, dt: dt)
            var d = DerivedScalars()
            d.bandwidthPeakGBs = engine.bandwidthPeakGBs
            d.mediaPeakGBs = engine.mediaPeakGBs
            d.anePeakWatts = engine.anePeakWatts
            d.gpuClockPeakMHz = engine.gpuClockPeakMHz
            d.memoryPageInRate = engine.memoryPageInRate
            d.memoryPageOutRate = engine.memoryPageOutRate
            d.memorySwapInRate = engine.memorySwapInRate
            d.memorySwapOutRate = engine.memorySwapOutRate
            d.memoryCompressionRate = engine.memoryCompressionRate
            out.append(d)
        }
        return out
    }
}
