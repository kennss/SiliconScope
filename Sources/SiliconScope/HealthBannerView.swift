//
//  File:      HealthBannerView.swift
//  Created:   2026-07-02
//  Developer: zhangchen / Mindstream
//  Overview:  A conditional overlay banner for System Health Advisor. Appears when the
//             system is stressed or overloaded, showing top CPU offenders and actionable
//             suggestions (Quit buttons). Visually consistent with the existing
//             WarningBanner style but richer: it lists the offending processes.
//  Notes:     Only shown when healthVerdict.level != .healthy. Dismissible via ✕; auto-
//             reappears if the verdict changes. Quit buttons send SIGTERM (graceful).
//
import SwiftUI
import SiliconScopeCore

struct HealthBannerView: View {
    let verdict: HealthVerdict
    let onDismiss: () -> Void

    private var isOverloaded: Bool { verdict.level == .overloaded }
    private var tint: Color { isOverloaded ? Color.red : Color.orange }
    private var fgColor: Color {
        isOverloaded
            ? Color(red: 1, green: 0.7, blue: 0.7)
            : Color(red: 1, green: 0.85, blue: 0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: isOverloaded ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                Text(headerText)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.65)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            // Offender list
            if !verdict.offenders.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(verdict.offenders) { offender in
                        HStack(spacing: 8) {
                            Text(offender.name)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                            Text(String(format: "%.0f%%", offender.cpuPercent))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.heat(min(1, offender.cpuPercent / 100)))
                            Text(String(format: "%.0f MB", offender.memoryMB))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                            Spacer()
                            if !offender.isSystemProcess {
                                Button("Quit") { ProcessControl.terminate(pid: offender.pid) }
                                    .font(.system(size: 10, weight: .medium))
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
                            }
                        }
                    }
                }
            }

            // Suggestion
            if let suggestion = verdict.suggestion {
                Text("💡 " + suggestion)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
        .foregroundStyle(fgColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .fill(tint.opacity(0.15)))
        }
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }

    private var headerText: String {
        let loadStr = String(format: "%.1f", verdict.loadAverage)
        switch verdict.level {
        case .overloaded:
            return "System Overloaded (Load \(loadStr) / \(verdict.coreCount) cores)"
        case .stressed:
            return "System Stressed (Load \(loadStr) / \(verdict.coreCount) cores)"
        case .healthy:
            return "System Healthy"
        }
    }
}
