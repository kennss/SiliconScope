//
//  File:      RecordBar.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Bottom transport bar for session recording (Phase 1): Record/Stop, an elapsed
//             timecode + live sample count, and an Export menu (CSV or lossless .ssrec). Bound to
//             SiliconScopeMonitor's @Observable recording state, pinned via .safeAreaInset.
//  Notes:     The record dot pulses via sample-count parity (no timer). Export uses NSSavePanel.
//             Phase 2 (replay) will add transport controls (play / scrub / timecode-seek) here.
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SiliconScopeCore

struct RecordBar: View {
    let monitor: SiliconScopeMonitor

    var body: some View {
        let recording = monitor.isRecording
        let dim = recording && monitor.recordingSampleCount % 2 == 1   // ~1 Hz pulse, no timer

        HStack(spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: recording ? "stop.fill" : "record.circle.fill")
                        .foregroundStyle(.red)
                        .opacity(dim ? 0.35 : 1)
                    Text(recording ? "Stop" : "Record")
                }
            }
            .buttonStyle(.plain)
            .help(recording ? "Stop recording" : "Record a session of every metric for trend analysis")

            if recording || monitor.hasRecording {
                Text(timecode(monitor.recordingElapsed))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text("\(monitor.recordingSampleCount) samples")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
            } else {
                Text("Record every metric to CSV / .ssrec for trend analysis")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }

            Spacer()

            if monitor.hasRecording && !recording {
                Button { replayJustRecorded() } label: {
                    Label("Replay", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .help("Replay the session you just recorded")

                Button { exportBoth() } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .help("Save .ssrec (replay) + .csv (analysis) to ~/SiliconScope")
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
    }

    private func toggle() {
        if monitor.isRecording { monitor.stopRecording() } else { monitor.startRecording() }
    }

    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    /// Loads the just-recorded temp .ssrec straight into replay — no export step needed.
    private func replayJustRecorded() {
        guard let url = monitor.recordingFileURL else { return }
        NotificationCenter.default.post(name: .openSiliconScopeRecording, object: nil, userInfo: ["url": url])
    }

    /// Saves BOTH the lossless .ssrec (replay) and a .csv (analysis), timestamped, into
    /// ~/SiliconScope by default (created if needed) — the panel lets you pick another location.
    private func exportBoth() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = Self.defaultRecordingsDir()
        panel.nameFieldStringValue = "SiliconScope-\(Self.timestamp())"   // no extension — both are added
        panel.message = "Saves two files: .ssrec (replay) and .csv (analysis)."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let base = chosen.deletingPathExtension()
        let ssrec = base.appendingPathExtension("ssrec")
        let csv = base.appendingPathExtension("csv")
        do {
            try monitor.exportRecording(to: ssrec)
            try monitor.exportRecordingCSV(to: csv)
            NSWorkspace.shared.activateFileViewerSelecting([ssrec, csv])
        } catch {
            NSSound.beep()
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// ~/SiliconScope, created on first use.
    private static func defaultRecordingsDir() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("SiliconScope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
