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
import SiliconScopeCore

struct ReplayBar: View {
    let controller: ReplayController
    let onExit: () -> Void

    var body: some View {
        let c = controller
        HStack(spacing: 10) {
            // A "REPLAY" status pill (you are NOT live) + a clearly-clickable exit button.
            Text("REPLAY").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
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
                .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
    private func timecode(_ s: TimeInterval) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
