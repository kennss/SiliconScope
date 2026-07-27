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
            Text("A metric can appear more than once — for example CPU as bars and again as a history graph. Reorder items by ⌘-dragging them in the menu bar; macOS remembers the position. Turn everything off to run SiliconScope with no menu-bar presence — Settings stays reachable from the Dock icon.")
        }
    }

    /// Add is a menu rather than a row per metric: the list is the state, and eight permanent
    /// "add" rows would read as eight items.
    private var addMenu: some View {
        Menu {
            ForEach(MetricKind.allCases, id: \.self) { metric in
                Button(metric.settingsLabel) { model.append(metric) }
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
                Text(summary)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.dim)
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
        let choices = item.metric.channels
        if choices.count > 1 && arity.lowerBound == arity.upperBound {
            // Exactly N ordered slots: which series is drawn on which row.
            ForEach(0..<arity.lowerBound, id: \.self) { slot in
                Picker(slotLabel(slot, of: arity.lowerBound), selection: channelBinding(slot)) {
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

    private func channelBinding(_ slot: Int) -> Binding<DataChannel> {
        Binding(get: { item.channels.indices.contains(slot) ? item.channels[slot] : item.metric.channels[0] },
                set: { channel in
                    var channels = item.channels
                    while channels.count <= slot { channels.append(item.metric.channels[0]) }
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
                        channels = item.metric.channels.filter { channels.contains($0) || $0 == channel }
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
        var fitted = channels.filter(metric.channels.contains)
        if fitted.count > mode.arity.upperBound {
            fitted = Array(fitted.prefix(mode.arity.upperBound))
        }
        for candidate in metric.defaultChannels + metric.channels where fitted.count < mode.arity.lowerBound {
            if !fitted.contains(candidate) { fitted.append(candidate) }
        }
        return fitted
    }
}
