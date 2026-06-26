//
//  File:      ReplayController.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Drives playback of a LoadedRecording: a playhead (frame index), play/pause, step,
//             seek/scrub, and a speed multiplier. Produces a DashboardState at the playhead so the
//             existing dashboard renders the recording exactly as it looked live. Phase 2 of the
//             record/replay feature.
//  Notes:     @MainActor @Observable (mirrors SiliconScopeMonitor). Advance is a Task loop that
//             sleeps the recording's own inter-frame gap / speed (gap clamped so a paused-then-
//             resumed recording's long gap doesn't look hung). Steps frame-to-frame (no
//             interpolation — the samples and their derived state are discrete).
//
import Foundation
import Observation
import SiliconScopeCore

@MainActor
@Observable
final class ReplayController {
    let recording: LoadedRecording
    private(set) var index = 0
    private(set) var isPlaying = false
    var speed: Double = 1
    private var task: Task<Void, Never>?

    init(recording: LoadedRecording) { self.recording = recording }

    var count: Int { recording.count }
    var time: TimeInterval { recording.frames.indices.contains(index) ? recording.frames[index].t : 0 }
    var duration: TimeInterval { recording.duration }

    /// The dashboard view-state at the current playhead.
    var state: DashboardState { DashboardState(replay: recording, at: index) }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying, recording.count > 1 else { return }
        if index >= recording.count - 1 { index = 0 }   // at the end → restart from the top
        isPlaying = true
        task = Task { [weak self] in
            while true {
                guard let self, self.isPlaying, self.index < self.recording.count - 1 else { break }
                let cur = self.recording.frames[self.index].t
                let next = self.recording.frames[self.index + 1].t
                let gap = min(max(next - cur, 0), 2) / max(self.speed, 0.1)   // clamp long gaps
                try? await Task.sleep(for: .seconds(gap))
                guard self.isPlaying else { break }   // self stays strong for this iteration
                self.index += 1
            }
            self?.isPlaying = false
        }
    }

    func pause() { isPlaying = false; task?.cancel(); task = nil }

    func stepBackward() { pause(); index = max(0, index - 1) }
    func stepForward() { pause(); index = min(recording.count - 1, index + 1) }

    /// Scrub to a time (seconds); independent of play state.
    func seek(toTime t: TimeInterval) { index = recording.index(forTime: t) }
}
