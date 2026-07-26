//
//  File:      ReplayBar.swift
//  Created:   2026-06-25
//  Updated:   2026-06-25
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Bottom transport bar shown while replaying a recording (in place of RecordBar):
//             Live (exit), step back / play-pause / step forward, a scrub slider + timecode, a
//             speed menu, and the recording's meta (chip · frame count). Bound to ReplayController.
//  Notes:     The slider's set closure seeks; get reflects the playhead so it tracks during play.
//
import SwiftUI
import AppKit
import SiliconScopeCore

struct ReplayBar: View {
    let controller: ReplayController
    let onExit: () -> Void

    var body: some View {
        let c = controller
        HStack(spacing: Space.card) {
            // A "REPLAY" status pill (you are NOT live) + a clearly-clickable exit button.
            Text("REPLAY").font(Theme.font(.detail, .strong))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Space.row).padding(.vertical, Space.hair)
                .background(Theme.accent.opacity(0.15), in: Capsule())
            Button(action: onExit) {
                Label("Exit to Live", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .help("Exit replay and return to the live dashboard")

            Button { c.stepBackward() } label: { Image(systemName: "backward.frame.fill") }.buttonStyle(.plain)
            Button { c.togglePlay() } label: {
                Image(systemName: c.isPlaying ? "pause.fill" : "play.fill")
            }.buttonStyle(.plain)
            Button { c.stepForward() } label: { Image(systemName: "forward.frame.fill") }.buttonStyle(.plain)

            Text("\(timecode(c.time)) / \(timecode(c.duration))")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.text)

            Slider(value: Binding(get: { c.time }, set: { c.seek(toTime: $0) }),
                   in: 0...max(c.duration, 0.001))
                .controlSize(.small)

            Menu("\(speedText(c.speed))×") {
                ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { sp in
                    Button("\(speedText(sp))×") { c.speed = sp }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.accent)

            Text("\(c.recording.meta.chip) · \(c.count) frames")
                .font(Theme.font(.caption)).foregroundStyle(Theme.dim).lineLimit(1)

            if c.sourceURL != nil {
                Button { export() } label: { Label("Save", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("Save this recording (.ssrec + .csv) to ~/SiliconScope")
            }
        }
        .font(Theme.font(.emphasis))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Space.section)
        .padding(.vertical, Space.row)
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: Layout.hairline).foregroundStyle(Theme.border), alignment: .top)
    }

    /// Save the currently-replayed recording: copy its .ssrec and write a .csv alongside,
    /// timestamped, into ~/SiliconScope (the panel allows another location). Reveals in Finder.
    private func export() {
        guard let src = controller.sourceURL else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = RecordingFiles.defaultDir()
        panel.nameFieldStringValue = RecordingFiles.timestampedName()   // no extension — both added
        panel.message = "Saves .ssrec (replay) + .csv (analysis)."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let base = chosen.deletingPathExtension()
        let ssrec = base.appendingPathExtension("ssrec")
        let csv = base.appendingPathExtension("csv")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: ssrec.path) { try fm.removeItem(at: ssrec) }
            try fm.copyItem(at: src, to: ssrec)
            try SessionRecorder.csv(fromRecordingAt: src).write(to: csv, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([ssrec, csv])
        } catch { NSSound.beep() }
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
