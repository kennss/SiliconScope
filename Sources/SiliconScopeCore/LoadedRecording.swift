//
//  File:      LoadedRecording.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  An in-memory, parsed .ssrec ready for replay: the meta, the frames, and a per-frame
//             table of the PATH-DEPENDENT derived scalars (the four decaying peaks + memory rates)
//             that can't be recovered from a trailing window. Precomputed once at load via the
//             shared MetricsEngine, so seeking to any frame is O(1) for scalars and O(60) to rebuild
//             the sparkline history window — smooth even on multi-hour recordings.
//  Notes:     The 60-sample sparkline History is NOT stored per frame (would be huge); it is rebuilt
//             on demand from the trailing frames via historyWindow(upTo:). index(forTime:) binary-
//             searches the frame timestamps. Pure value type.
//
import Foundation

/// The path-dependent scalars captured at one frame during the load-time fold.
public struct DerivedScalars: Sendable, Equatable {
    public var bandwidthPeakGBs = 0.0
    public var mediaPeakGBs = 0.0
    public var anePeakWatts = 0.0
    public var gpuClockPeakMHz = 0.0
    public var memoryPageInRate = 0.0
    public var memoryPageOutRate = 0.0
    public var memorySwapInRate = 0.0
    public var memorySwapOutRate = 0.0
    public var memoryCompressionRate = 0.0
    public init() {}
}

public struct LoadedRecording: Sendable {
    public let meta: RecordingMeta
    public let frames: [RecordedFrame]
    public let derived: [DerivedScalars]   // parallel to `frames`

    public init(meta: RecordingMeta, frames: [RecordedFrame], derived: [DerivedScalars]) {
        self.meta = meta; self.frames = frames; self.derived = derived
    }

    public var count: Int { frames.count }
    public var duration: TimeInterval { frames.last?.t ?? 0 }

    /// Index of the last frame whose timestamp is ≤ `t` (clamped to a valid index).
    public func index(forTime t: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        var lo = 0, hi = frames.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frames[mid].t <= t { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }

    /// Rebuilds the rolling sparkline history (≤60 samples) as it stood at `index` by replaying
    /// only the trailing window through a fresh History — O(60), independent of recording length.
    public func historyWindow(upTo index: Int) -> MetricsEngine.History {
        var h = MetricsEngine.History()
        guard !frames.isEmpty else { return h }
        let end = min(max(index, 0), frames.count - 1)
        let start = max(0, end - 59)
        for i in start...end { h.push(frames[i].snapshot) }
        return h
    }
}
