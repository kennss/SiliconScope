//
//  File:      MenuBarItemsSettings.swift
//  Created:   2026-07-27
//  Updated:   2026-07-27
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The "Menu bar items" section of Settings (#27, phase 4b): the list of item instances
//             with add / duplicate / remove, and per-instance configuration of render mode and data
//             channels. Replaces the eight fixed on/off toggles, which could only express "this
//             metric is shown in the one way it is drawn".
//  Notes:     The channel controls are DERIVED from `GlyphMode.arity`, not written per metric: a
//             fixed arity (twoLine = 2, value = 1) becomes that many ordered pickers, a range
//             (bars = 1...4) becomes a toggle set bounded by the range. Adding a mode therefore
//             needs no new UI here.
//             ⚠️ No reorder control, deliberately — macOS owns status-item position (it persists
//             the user's ⌘-drag per `autosaveName`) and there is no API to set it. A list that
//             pretended to order items would lie; the footer says how to reorder instead.
//             Modes with a fixed presentation (`icon`, `composite`) expose no channel controls,
//             because their renderer takes its data from the metric, not from a selection.
//
import SwiftUI
import SiliconScopeCore

struct MenuBarItemsSettings: View {
    @ObservedObject private var model = MenuBarItemsModel.shared

    var body: some View {
        Section {
            if model.items.isEmpty {
                Text("No menu-bar items. SiliconScope is running, but nothing is shown in the menu bar.")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(model.items) { item in
                MenuBarItemRow(item: item, model: model)
            }
            addMenu
        } header: {
            Text("Menu bar items")
        } footer: {
            Text("Add gives you a metric you don't have yet. To show one twice — CPU as bars and again as a graph — use Duplicate on its row, then change the copy's style. Reorder items by ⌘-dragging them in the menu bar; macOS remembers the position. Remove them all to run SiliconScope with no menu-bar presence — Settings stays reachable from the Dock icon.")
        }
    }

    /// Add is a menu rather than a row per metric: the list is the state, and eight permanent
    /// "add" rows would read as eight items.
    ///
    /// A metric already in the menu bar is shown DISABLED rather than hidden, so the list is always
    /// the same eight rows in the same order and the greyed ones answer "where is CPU?" by
    /// themselves.
    ///
    /// "Add" means add something you do not have. A metric CAN appear more than once — that is the
    /// point of the instance model — but the second one comes from **Duplicate** on the existing
    /// row, which starts from that item's configuration instead of from the metric's defaults.
    /// Offering it here too made adding a duplicate look like an ordinary add.
    private var addMenu: some View {
        Menu {
            ForEach(MetricKind.allCases, id: \.self) { metric in
                Button(metric.settingsLabel) { model.append(metric) }
                    .disabled(model.isPinned(metric))
            }
        } label: {
            Label("Add item", systemImage: "plus")
        }
    }
}

// MARK: - One row

private struct MenuBarItemRow: View {
    let item: MenuBarItemConfig
    @ObservedObject var model: MenuBarItemsModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            configuration
        } label: {
            HStack(spacing: Space.row) {
                Text(item.metric.glyphLabel)
                    .font(Theme.font(.detail, .strong).monospaced())
                    .foregroundStyle(Theme.accent)
                Text(item.metric.settingsLabel)
                    .font(Theme.font(.body))
                Spacer()
                // One line, always: a wrapped summary makes that row taller than its neighbours
                // and the list stops reading as a list of equals.
                Text(summary)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// "Bars · E, P" — what the item draws and from what, at a glance, so the list is readable
    /// without expanding every row.
    private var summary: String {
        guard !item.channels.isEmpty, item.mode != .composite, item.mode != .icon else {
            return item.mode.label
        }
        return "\(item.mode.label) · \(item.channels.map(\.settingsLabel).joined(separator: ", "))"
    }

    @ViewBuilder
    private var configuration: some View {
        // Only offer a style picker when there is a choice to make.
        if item.metric.supportedModes.count > 1 {
            Picker("Style", selection: modeBinding) {
                ForEach(item.metric.supportedModes, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        channelControls
        HStack {
            Button("Duplicate") { model.duplicate(item.id) }
            Button("Remove", role: .destructive) { model.remove(item.id) }
            Spacer()
        }
    }

    /// Derived from the mode's arity — see the file header.
    @ViewBuilder
    private var channelControls: some View {
        let arity = item.mode.arity
        // Mode-aware: a histogram may only draw channels that have a series behind them.
        let choices = item.metric.channels(for: item.mode)
        if choices.count > 1 && arity.lowerBound == arity.upperBound {
            // Exactly N ordered slots: which series is drawn on which row.
            ForEach(0..<arity.lowerBound, id: \.self) { slot in
                Picker(slotLabel(slot, of: arity.lowerBound), selection: channelBinding(slot, choices)) {
                    ForEach(choices, id: \.self) { channel in
                        Text(channel.settingsLabel).tag(channel)
                    }
                }
            }
        } else if choices.count > 1 {
            // A bounded set: order follows the metric's own channel order.
            ForEach(choices, id: \.self) { channel in
                Toggle(channel.settingsLabel, isOn: toggleBinding(channel, arity: arity))
                    .disabled(isLocked(channel, arity: arity))
            }
        }
    }

    private func slotLabel(_ slot: Int, of count: Int) -> String {
        count == 1 ? "Value" : (slot == 0 ? "Top row" : "Bottom row")
    }

    /// A channel that cannot be turned off without breaking the mode's minimum.
    private func isLocked(_ channel: DataChannel, arity: ClosedRange<Int>) -> Bool {
        item.channels.contains(channel) && item.channels.count <= arity.lowerBound
    }

    // MARK: - Bindings
    //
    // Every edit goes through `model.update`, which repairs an invalid result rather than storing
    // it — changing the style to one whose arity the current channels do not fit is a normal
    // interaction, not an error to reject.

    private var modeBinding: Binding<GlyphMode> {
        Binding(get: { item.mode },
                set: { mode in
                    var edited = item
                    edited.mode = mode
                    edited.channels = fitted(item.channels, to: mode, of: item.metric)
                    model.update(edited)
                })
    }

    private func channelBinding(_ slot: Int, _ choices: [DataChannel]) -> Binding<DataChannel> {
        let fallback = choices.first ?? item.metric.channels[0]
        return Binding(get: { item.channels.indices.contains(slot) ? item.channels[slot] : fallback },
                set: { channel in
                    var channels = item.channels
                    while channels.count <= slot { channels.append(fallback) }
                    channels[slot] = channel
                    var edited = item
                    edited.channels = channels
                    model.update(edited)
                })
    }

    private func toggleBinding(_ channel: DataChannel, arity: ClosedRange<Int>) -> Binding<Bool> {
        Binding(get: { item.channels.contains(channel) },
                set: { on in
                    var channels = item.channels
                    if on {
                        guard channels.count < arity.upperBound else { return }
                        // Keep the metric's declared order so bar colours stay in a stable sequence.
                        channels = item.metric.channels(for: item.mode).filter { channels.contains($0) || $0 == channel }
                    } else {
                        guard channels.count > arity.lowerBound else { return }
                        channels.removeAll { $0 == channel }
                    }
                    var edited = item
                    edited.channels = channels
                    model.update(edited)
                })
    }

    /// Trims or pads a channel selection to fit a newly chosen mode, preferring what the user
    /// already picked over the metric's defaults.
    private func fitted(_ channels: [DataChannel], to mode: GlyphMode, of metric: MetricKind) -> [DataChannel] {
        let allowed = metric.channels(for: mode)
        var fitted = channels.filter(allowed.contains)
        if fitted.count > mode.arity.upperBound {
            fitted = Array(fitted.prefix(mode.arity.upperBound))
        }
        // Switching Disk from "Two lines · Used, Free" to a histogram drops both — neither has a
        // series — so the padding pass must fill from what the NEW mode allows, not from the
        // metric's defaults, or the item would repair itself back to a chart of nothing.
        for candidate in metric.defaultChannels + allowed where fitted.count < mode.arity.lowerBound {
            if allowed.contains(candidate), !fitted.contains(candidate) { fitted.append(candidate) }
        }
        return fitted
    }
}
