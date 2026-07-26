//
//  File:      RecordBar.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Bottom bar for the LIVE dashboard: Record/Stop (with elapsed timecode + sample
//             count while recording), and a Replay menu to revisit a session. Stopping a recording
//             drops straight into replay of what was just captured (saving happens there, after).
//  Notes:     The record dot pulses via sample-count parity (no timer). Entering replay is done by
//             posting .openSiliconScopeRecording (handled by DashboardContainer); the open panel
//             defaults to ~/SiliconScope.
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

        HStack(spacing: Space.section) {
            Button(action: toggle) {
                HStack(spacing: Space.tight) {
                    Image(systemName: recording ? "stop.fill" : "record.circle.fill")
                        .foregroundStyle(.red)
                        .opacity(dim ? 0.35 : 1)
                    Text(recording ? "Stop" : "Record")
                }
            }
            .buttonStyle(.plain)
            .help(recording ? "Stop and replay this recording" : "Record a session of every metric")

            if recording {
                Text(timecode(monitor.recordingElapsed))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text("\(monitor.recordingSampleCount) samples")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.dim)
            } else {
                Text("Record every metric, then replay it like a DVR")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.faint)
            }

            Spacer()

            if !recording {
                Menu {
                    if monitor.recordingFileURL != nil {
                        Button("Replay Last Session") { replay(monitor.recordingFileURL) }
                    }
                    Button("Open Recording…") { openPanel() }
                } label: {
                    Label("Replay", systemImage: "play.rectangle.fill")
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.accent)
            }
        }
        .font(Theme.font(.emphasis))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Space.section)
        .padding(.vertical, Space.row)
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: Layout.hairline).foregroundStyle(Theme.border), alignment: .top)
    }

    private func toggle() {
        if monitor.isRecording {
            monitor.stopRecording()
            replay(monitor.recordingFileURL)   // Stop → straight into replay of what was just captured
        } else {
            monitor.startRecording()
        }
    }

    /// Hands a recording URL to DashboardContainer to enter replay.
    private func replay(_ url: URL?) {
        guard let url else { return }
        NotificationCenter.default.post(name: .openSiliconScopeRecording, object: nil, userInfo: ["url": url])
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = RecordingFiles.defaultDir()
        if let ssrec = UTType(filenameExtension: "ssrec") { panel.allowedContentTypes = [ssrec] }
        if panel.runModal() == .OK { replay(panel.url) }
    }

    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
