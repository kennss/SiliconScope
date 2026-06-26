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
                Menu {
                    Button("Export CSV…") { export(csv: true) }
                    Button("Export Recording (.ssrec)…") { export(csv: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.accent)
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

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SiliconScope-session.\(csv ? "csv" : "ssrec")"
        if csv { panel.allowedContentTypes = [.commaSeparatedText] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv { try monitor.exportRecordingCSV(to: url) } else { try monitor.exportRecording(to: url) }
        } catch {
            NSSound.beep()
        }
    }
}
