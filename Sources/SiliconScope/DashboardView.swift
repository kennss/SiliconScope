//
//  File:      DashboardView.swift
//  Created:   2026-06-08
//  Updated:   2026-07-15
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Full-window dashboard. Header (chip, cores, SoC power, battery), then
//             CPU + GPU side by side, combined Memory|Bandwidth and Network|Disk cards
//             (btop-style vertical split), a Sensors accordion, and the process table.
//  Notes:     No separate Power/Thermal cards — power lives in the header, temperature
//             in the Sensors card. Combined cards split left/right with a Divider.
//             allWarnings() adds context-aware banners (bandwidth-bound, GPU throttle)
//             on top of the snapshot's own data-level warnings.
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SiliconScopeCore

/// Reports the hosting window's on-screen visibility (occlusion + miniaturize) so the dashboard
/// can pause its expensive live re-render when it isn't actually visible. Measured cost split:
/// the data layer (IOReport/SMC/per-process sampling) is ~0.6% CPU, while the live SwiftUI chart
/// rendering is essentially the entire footprint — so when the window is hidden, re-rendering it
/// is pure waste. The sampler and menu-bar items keep running (they need fresh data); only the
/// chart rendering is gated. Also fixes the "high CPU while minimized" half of issue #13.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // updateNSView runs on the main actor; by now the view is in a window (nil on the first
        // call before insertion — attach() no-ops until a window exists, then latches once).
        context.coordinator.attach(nsView.window, onChange)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    // NSObject + selector observers (not closure blocks) so nothing non-Sendable is captured.
    // @MainActor so it may read the window's main-actor state; window notifications post on main.
    @MainActor final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var onChange: ((Bool) -> Void)?
        func attach(_ window: NSWindow?, _ onChange: @escaping (Bool) -> Void) {
            guard let window, self.window == nil else { return }
            self.window = window
            self.onChange = onChange
            let nc = NotificationCenter.default
            // Recompute on occlusion / (de)miniaturize, and on becoming key/main so a re-opened
            // window (ordered back in) resumes live rendering.
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification] {
                nc.addObserver(self, selector: #selector(report), name: name, object: window)
            }
            // A CLOSED (ordered-out) window does NOT post an occlusion change and its
            // occlusionState stays `.visible`, so without this the dashboard keeps re-rendering
            // full-rate to a hidden window (measured: ~685 Energy Impact with the window closed).
            nc.addObserver(self, selector: #selector(reportHidden), name: NSWindow.willCloseNotification, object: window)
            report()
        }
        @objc private func report() {
            guard let w = window else { return }
            // isVisible is false for a closed/ordered-out window (occlusionState alone is not enough).
            onChange?(w.isVisible && w.occlusionState.contains(.visible) && !w.isMiniaturized)
        }
        // willClose fires before the window leaves screen (isVisible may still be true), so force hidden.
        @objc private func reportHidden() { onChange?(false) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// Hosts the dashboard: chooses the data source (live monitor or session replay), builds the
// DashboardState in its body so @Observable / playhead changes re-render, and pins the matching
// bottom bar (RecordBar live, ReplayBar in replay). Enters replay via ⌘O (notification) or a
// dropped .ssrec; exits back to live from the ReplayBar. While the window is off-screen it shows
// a frozen last frame and reads nothing from the monitor, so live updates stop re-rendering.
struct DashboardContainer: View {
    let monitor: SiliconScopeMonitor
    @State private var replay: ReplayController?
    @State private var loadError: String?
    @State private var dashVisible = true        // false when the window is occluded or minimized
    @State private var frozen: DashboardState?   // last live frame, shown (not re-rendered) while hidden

    var body: some View {
        content
            .background(WindowVisibilityObserver { visible in
                // Capture the last live frame as we go off-screen so the frozen branch has it.
                if !visible && dashVisible { frozen = DashboardState(live: monitor) }
                dashVisible = visible
            })
            .onReceive(NotificationCenter.default.publisher(for: .openSiliconScopeRecording)) { note in
                if let url = note.userInfo?["url"] as? URL { open(url) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .alert("Couldn't open recording",
                   isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("OK") { loadError = nil }
            } message: { Text(loadError ?? "") }
            .sheet(isPresented: Binding(get: { monitor.focusedPID != nil && replay == nil },
                                        set: { if !$0 { monitor.endFocus() } })) {
                InspectorView(monitor: monitor)
            }
    }

    @ViewBuilder private var content: some View {
        if let replay {
            DashboardView(state: replay.state, onBenchmark: nil)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ReplayBar(controller: replay, onExit: { self.replay = nil })
                }
        } else if dashVisible {
            DashboardView(state: DashboardState(live: monitor),
                          onBenchmark: { Task { await monitor.runBenchmark() } },
                          onInspect: { monitor.focus($0.pid) })
                .safeAreaInset(edge: .bottom, spacing: 0) { RecordBar(monitor: monitor) }
        } else {
            // Off-screen: render the frozen last frame, reading nothing from the monitor, so
            // per-tick snapshot changes no longer trigger chart re-renders. (Recording keeps
            // running in the monitor loop regardless; the menu bar stays live via its own sync.)
            DashboardView(state: frozen ?? DashboardState(live: monitor), onBenchmark: nil)
        }
    }

    private func open(_ url: URL) {
        do { replay = ReplayController(recording: try SessionReader.load(url), sourceURL: url) }
        catch { replay = nil; loadError = Self.message(for: error) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "ssrec" else { return }
            DispatchQueue.main.async { open(url) }
        }
        return true
    }

    private static func message(for error: Error) -> String {
        switch error as? SessionReader.LoadError {
        case .empty:                    return "The file is empty."
        case .missingMeta:              return "Not a SiliconScope recording (missing header)."
        case .noFrames:                 return "The recording has no frames."
        case .unsupportedVersion(let v): return "Recorded by a newer SiliconScope (format v\(v))."
        case nil:                       return error.localizedDescription
        }
    }
}

struct DashboardView: View {
    let state: DashboardState
    var onBenchmark: (() -> Void)? = nil   // nil → replay: hides the benchmark control + process kill
    var onInspect: ((ProcessRow) -> Void)? = nil   // nil → replay: process inspection disabled
    @State private var dismissedWarnings: Set<String> = []   // user-dismissed warnings (until the episode ends)
    @State private var shownWarnings: [SystemSnapshot.Warning] = []   // DEBOUNCED (lingering) set actually displayed
    @State private var warningClearTask: Task<Void, Never>? = nil     // pending "hide after linger" task
    @AppStorage("showWarningBanner") private var showWarningBanner = true   // #18: let sysmon users opt out of the banner

    var body: some View {
        let s = state
        let snapshot = s.snapshot
        let warnings = allWarnings(s)
        // shownWarnings is the DEBOUNCED set (lingers a few seconds after the condition clears) so an
        // oscillating pressure/throttle never makes the banner flicker in and out (#18).
        let visibleWarnings = shownWarnings.filter { !dismissedWarnings.contains(Self.warningKey($0)) }
        ScrollView {
            VStack(spacing: 4) {
                HeaderView(topology: s.topology, power: snapshot.power, battery: snapshot.battery)

                // AI cockpit pair, side by side (matches the rest of the 2-column grid and
                // saves a stacked row of vertical space).
                HStack(alignment: .top, spacing: 6) {
                    AIWorkloadCard(snapshot: snapshot,
                                   bottleneck: s.bottleneck,
                                   ceilingGBs: s.bandwidthCeilingGBs,
                                   cpuThrottling: s.cpuThrottling,
                                   cpuClockDrop: s.cpuClockDropFraction,
                                   gpuThrottling: s.gpuThrottling,
                                   gpuClockDrop: s.gpuClockDropFraction,
                                   memoryRisk: s.memoryRisk,
                                   onInspect: onInspect,
                                   allowKill: onBenchmark != nil)
                    AIRuntimeCard(runtime: snapshot.aiRuntime,
                                  api: snapshot.runtimeAPI,
                                  budget: snapshot.memoryBudget,
                                  memoryRisk: s.memoryRisk,
                                  cpuOffloadLikely: snapshot.aiCPUOffloadLikely,
                                  likelyEngine: snapshot.likelyAIEngine,
                                  isBenchmarking: s.isBenchmarking,
                                  benchmark: s.benchmark,
                                  benchmarkError: s.benchmarkError,
                                  onBenchmark: onBenchmark ?? {},
                                  allowBenchmark: onBenchmark != nil)
                }
                .frame(minHeight: 108)

                HStack(spacing: 6) {
                    CPUCard(cpu: snapshot.cpu, topology: s.topology,
                            eHistory: s.history.eCPU, pHistory: s.history.pCPU,
                            throttling: s.cpuThrottling, clockDrop: s.cpuClockDropFraction)
                    AcceleratorCard(gpu: snapshot.gpu, power: snapshot.power, bandwidth: snapshot.bandwidth,
                                    anePeak: s.anePeakWatts, mediaPeak: s.mediaPeakGBs,
                                    gpuHistory: s.history.gpu, gpuMemHistory: s.history.gpuMem,
                                    mediaHistory: s.history.media, aneHistory: s.history.ane,
                                    throttling: s.gpuThrottling)
                }
                .frame(height: 166)   // fixed: the fill-graph absorbs content changes (shrinks/grows) so the card size stays put

                HStack(alignment: .top, spacing: 6) {
                    MemoryBandwidthCard(memory: snapshot.memory, bandwidth: snapshot.bandwidth,
                                        bandwidthPeak: s.bandwidthPeakGBs,
                                        memHistory: s.history.memory, bwHistory: s.history.bandwidth)
                    NetworkDiskCard(network: snapshot.network, disk: snapshot.disk,
                                    downHistory: s.history.netDown, upHistory: s.history.netUp,
                                    readHistory: s.history.diskRead, writeHistory: s.history.diskWrite)
                }
                // minHeight (not fixed height): both cards here are graphless — their trends live
                // INSIDE the sections (Spacer-pinned), so unlike the CPU/GPU fill-graph row above they
                // don't need a bounded height. The dense Memory column's intrinsic height (~188pt, a
                // constant row set) can exceed a fixed 176 by a few points under some macOS versions'
                // text metrics and spill into the CPU card (#25, a re-run of #23). Growing to fit the
                // content makes the overflow structurally impossible — same pattern as the row-1 pair.
                .frame(minHeight: 176)

                HStack(spacing: 6) {
                    SensorsCard(temperature: snapshot.temperature, thermal: snapshot.thermal)
                    ProcessCard(processes: snapshot.processes, allowKill: onBenchmark != nil, onInspect: onInspect)
                }
                // FIXED height (not minHeight): the Processes card scrolls its list INTERNALLY, so it
                // needs a bounded height — minHeight lets the whole list expand and balloons the window.
                .frame(height: 196)
            }
            .padding(8)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        // Warnings (memory-pressure / GPU-throttle) float as an OVERLAY at the top — shown for as
        // long as the condition holds, never inserted inline, so the cards never reflow/jump (#16).
        // It sits over the header (the least-critical row) while active and slides away when the
        // condition clears; the per-condition detail also lives persistently in the cards
        // (Memory pressure %, AI Workload thermal verdict).
        .overlay(alignment: .top) {
            if showWarningBanner && !visibleWarnings.isEmpty {
                WarningBanner(warnings: visibleWarnings,
                              onDismiss: { dismissedWarnings.insert(Self.warningKey($0)) })
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .frame(maxWidth: 620)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: visibleWarnings.isEmpty)
        // Debounce (#18): keep the banner up while active; when the condition clears, linger 4 s before
        // hiding so a brief oscillation doesn't respawn it — a recurrence within the window cancels the
        // hide. Replaces the old "forget the dismissal the instant it clears", which caused the flicker.
        .onChange(of: warnings) { _, now in
            if now.isEmpty {
                if warningClearTask == nil {
                    warningClearTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        shownWarnings = []; dismissedWarnings = []; warningClearTask = nil
                    }
                }
            } else {
                warningClearTask?.cancel(); warningClearTask = nil
                shownWarnings = now
                dismissedWarnings.formIntersection(Set(now.map(Self.warningKey)))
            }
        }
    }

    // Stable key per warning condition — strip digits so live values in the message (e.g. the GPU
    // clock MHz in the throttle text) don't make a persisting warning look like a brand-new one.
    private static func warningKey(_ w: SystemSnapshot.Warning) -> String {
        "\(w.level)|" + w.message.filter { !$0.isNumber }
    }

    private func allWarnings(_ s: DashboardState) -> [SystemSnapshot.Warning] {
        // Bandwidth-bound is no longer a banner alert — it's the AI Workload verdict
        // (AIWorkloadCard). The banner keeps only the data-level + throttle alarms.
        var warnings = s.snapshot.warnings
        if s.gpuThrottling {
            let level: SystemSnapshot.Warning.Level = s.snapshot.thermal.pressure == .critical ? .critical : .warning
            warnings.append(.init(level: level,
                                  message: String(format: "GPU throttling — clock %.0f MHz (-%.0f%% vs peak)",
                                                   s.snapshot.gpu.freqMHz, s.gpuClockDropFraction * 100)))
        }
        return warnings
    }
}

// MARK: - Header

private struct HeaderView: View {
    let topology: CPUTopology?
    let power: PowerSample
    let battery: BatteryInfo
    @AppStorage("menubar.battery") private var batteryMB = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("SiliconScope").font(.system(size: 14, weight: .bold, design: .monospaced))
            if let t = topology {
                Text(t.chipName).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                Text("\(t.eCoreCount + t.pCoreCount) cores · \(t.eCoreCount)E+\(t.pCoreCount)P")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            Spacer()
            Text(String(format: "%.1f W", power.socWatts))
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.dim)
            if battery.hasBattery {
                HStack(spacing: 3) {
                    if battery.isCharging {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.heat(0.2))
                    }
                    Text("\(Int(battery.percent.rounded()))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(battery.percent < 20 ? Theme.heat(1) : Theme.text)
                    MenuBarPin(isOn: $batteryMB)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct WarningBanner: View {
    let warnings: [SystemSnapshot.Warning]
    var onDismiss: ((SystemSnapshot.Warning) -> Void)? = nil

    var body: some View {
        VStack(spacing: 5) {
            ForEach(warnings) { warning in
                let critical = warning.level == .critical
                HStack(spacing: 8) {
                    Image(systemName: critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(warning.message).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    Spacer()
                    if let onDismiss {
                        Button { onDismiss(warning) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.65)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss until it clears")
                    }
                }
                .foregroundStyle(critical ? Color(red: 1, green: 0.7, blue: 0.7) : Color(red: 1, green: 0.85, blue: 0.6))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background {
                    // Opaque base so the floating banner cleanly covers the header behind it
                    // (no see-through blending), with the alert tint layered on top.
                    RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .fill((critical ? Color.red : Color.orange).opacity(0.18)))
                }
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder((critical ? Color.red : Color.orange).opacity(0.5), lineWidth: 1))
            }
        }
    }
}

// MARK: - AI Workload (hero)

/// The hero card: a per-engine STATE summary — "where is the work landing, and what limits it?"
/// Replaces the old repeated raw numbers (Mem BW / GPU %, already shown in their own cards) with
/// three descriptive, colour-coded states (CPU / GPU-Media-ANE / Memory) built from existing verdicts.
/// Keeps the AI-workload lens: the GPU line surfaces ANE / Media activity, not just a GPU percent.
private struct AIWorkloadCard: View {
    let snapshot: SystemSnapshot
    let bottleneck: Bottleneck
    let ceilingGBs: Double
    let cpuThrottling: Bool
    let cpuClockDrop: Double
    let gpuThrottling: Bool
    let gpuClockDrop: Double
    let memoryRisk: MemoryBudget.Risk
    var onInspect: ((ProcessRow) -> Void)? = nil   // tap the top process → focus it in the Inspector
    var allowKill = false                           // false in replay — recorded PIDs are stale
    @State private var pendingKill: ProcessRow?
    @State private var pendingForce = false

    private let alertColor  = Color(red: 0.88, green: 0.37, blue: 0.37)   // red — throttle / swapping
    private let amberColor  = Color(red: 0.87, green: 0.66, blue: 0.28)   // amber — pressure
    private var activeColor: Color { MetricPalette.gpuC }    // green — busy/normal-active
    private var aneColor: Color    { MetricPalette.aneC }    // purple — ANE
    private var mediaColor: Color  { MetricPalette.mediaC }  // orange — media engine

    private var topProcess: ProcessRow? { snapshot.processes.max(by: { $0.cpuPercent < $1.cpuPercent }) }

    // The card's headline: a semantic read of what the AI workload actually is (ANE/CoreML vs an LLM
    // on Metal vs GPU+video vs idle). Uses GENUINE-compute thresholds (aneWatts / aiModelActive /
    // gpuComputeBusy), NOT likelyAIEngine's loose 0.25 GPU hint — so it never contradicts the GPU row
    // below (light desktop GPU at ~idle watts must read Idle here, exactly as it does there).
    private var aiVerdict: (Color, String) {
        if snapshot.power.aneWatts > 1.5 { return (aneColor, "ANE (CoreML)") }
        if snapshot.aiModelActive        { return (activeColor, "LLM (GPU/Metal)") }
        if snapshot.gpuComputeBusy {
            return (activeColor, snapshot.bandwidth.mediaGBs > 0.5 ? "GPU active — incl. video" : "GPU active")
        }
        return (Theme.dim, "Idle")
    }

    // CPU: throttled > active > idle. The top process is rendered separately (cpuRow) as an ACTIONABLE
    // element — describe the driver, and let the user act on it if they choose (never judge/suggest).
    private var cpuState: (Color, String) {
        if cpuThrottling { return (alertColor, "Throttled") }
        if snapshot.cpu.pUsage > 0.5 || snapshot.cpu.eUsage > 0.7 { return (activeColor, "Active") }
        return (Theme.dim, "Idle")
    }

    // The accelerator cluster is shown as three EXPLICIT engine rows (GPU / ANE / Media) so each is
    // honestly labelled — no "ANE active" sitting under a "GPU" label. Each dot is coloured when its
    // engine does genuine work, dim when idle. This is the AI-workload lens: at a glance you see WHICH
    // engine a workload lands on (e.g. CoreML ASR → ANE active while the GPU stays idle).
    private var gpuEngine: (Color, String, String) {
        if gpuThrottling {
            return (alertColor, "throttled",
                    String(format: "%.0f MHz · −%.0f%%", snapshot.gpu.freqMHz, gpuClockDrop * 100))
        }
        if snapshot.gpuComputeBusy {
            return (activeColor, "active",
                    String(format: "%.0f%% · %.1f W", snapshot.gpu.usagePercent, snapshot.power.gpuWatts))
        }
        return (Theme.dim, "idle", "")
    }
    private var aneEngine: (Color, String, String) {
        snapshot.power.aneWatts > 0.5
            ? (aneColor, "active", String(format: "%.1f W", snapshot.power.aneWatts))
            : (Theme.dim, "idle", "")
    }
    private var mediaEngine: (Color, String, String) {
        snapshot.bandwidth.mediaGBs > 0.1
            ? (mediaColor, "active", String(format: "%.1f GB/s", snapshot.bandwidth.mediaGBs))
            : (Theme.dim, "idle", "")
    }

    private var bwFraction: Double { ceilingGBs > 0 ? min(1, snapshot.bandwidth.totalGBs / ceilingGBs) : 0 }

    // Memory STATE: swapping > pressure > bandwidth-bound > normal. Bandwidth magnitude lives in the
    // dedicated "% of ceiling" bar below, so this line describes the memory side — including sticky
    // swap, which is *shown* (not alarmed) per instrument-not-nanny.
    private var memState: (Color, String, String) {
        switch memoryRisk {
        case .swapping:
            return (alertColor, "Swapping", String(format: "pressure %.0f%%", snapshot.memory.pressurePercent))
        case .tight:
            return (amberColor, "Pressure", String(format: "%.0f%%", snapshot.memory.pressurePercent))
        case .ok:
            if bwFraction > 0.7 {
                // BandwidthSampler's PMP-histogram fallback (see its file header) clamps
                // per-requestor values at a labeled "32GB/s" bucket and sums many requestor
                // channels into `totalGBs`, so it can read a high fraction of the chip's spec
                // ceiling without genuinely reflecting it — label it as an estimate rather than
                // assert precision the reading doesn't have.
                let label = snapshot.bandwidth.isEstimated ? "Bandwidth-bound (est.)" : "Bandwidth-bound"
                return (activeColor, label, "near memory-BW ceiling")
            }
            let swapGB = Double(snapshot.memory.swapUsedBytes) / 1_073_741_824
            return (Theme.dim, "Normal", swapGB >= 0.5 ? String(format: "swap %.1f GB", swapGB) : "")
        }
    }

    var body: some View {
        Card(title: "AI Workload") {
            VStack(alignment: .leading, spacing: 2) {
                // Headline: what the workload IS (semantic), above the per-engine breakdown.
                HStack(spacing: 8) {
                    Circle().fill(aiVerdict.0).frame(width: 8, height: 8)
                    Text(aiVerdict.1)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(aiVerdict.0)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                cpuRow()
                stateRow("GPU",   gpuEngine)
                stateRow("ANE",   aneEngine)
                stateRow("Media", mediaEngine)
                stateRow("Mem",   memState)
            }
        }
        .confirmationDialog(
            pendingKill.map { "\(pendingForce ? "Force kill" : "Kill") \($0.name)  (pid \($0.pid))?" } ?? "",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingForce ? "Force Kill" : "Kill", role: .destructive) {
                if let p = pendingKill {
                    if pendingForce { ProcessControl.forceKill(pid: p.pid) } else { ProcessControl.terminate(pid: p.pid) }
                }
                pendingKill = nil
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        }
    }

    // CPU row with an ACTIONABLE top process: tap → Inspector, right-click → Quit / Force Quit. Same
    // affordance as the Processes card — a fact you can act on, not a suggestion the tool pushes.
    private func cpuRow() -> some View {
        HStack(spacing: 8) {
            Text("CPU")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.faint).frame(width: 42, alignment: .leading)
            Circle().fill(cpuState.0).frame(width: 7, height: 7)
            Text(cpuState.1)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(cpuState.0).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            if let top = topProcess {
                Text("top: \(top.name) \(Int(top.cpuPercent.rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(onInspect != nil ? Theme.text : Theme.dim)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
                    .onTapGesture { onInspect?(top) }
                    .contextMenu {
                        if onInspect != nil { Button("Inspect \(top.name)") { onInspect?(top) } }
                        if allowKill {
                            Button("Kill \(top.name)") { pendingKill = top; pendingForce = false }
                            Button("Force Kill \(top.name)", role: .destructive) { pendingKill = top; pendingForce = true }
                        }
                    }
                    .help(onInspect != nil ? "Tap to inspect · right-click for actions" : "")
            }
        }
    }

    private func stateRow(_ label: String, _ s: (Color, String, String)) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: 42, alignment: .leading)
            Circle().fill(s.0).frame(width: 7, height: 7)
            Text(s.1)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(s.0)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(s.2)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - AI Runtime cockpit (features ① + ②)

/// Composes runtime detection (①) and the memory budget (②) under the hero. The ③
/// model/tokens-per-sec lines arrive with the opt-in runtime API.
private struct AIRuntimeCard: View {
    let runtime: AIRuntimeSample
    let api: RuntimeAPISample
    let budget: MemoryBudget
    let memoryRisk: MemoryBudget.Risk
    let cpuOffloadLikely: Bool
    let likelyEngine: String
    let isBenchmarking: Bool
    let benchmark: BenchmarkRecord?
    let benchmarkError: String?
    let onBenchmark: () -> Void
    var allowBenchmark = true        // false during replay — no live runtime to benchmark

    private static let gb = 1_073_741_824.0

    /// A model is genuinely loaded/resident (vs. a bare idle daemon) — only then do we
    /// attribute an engine/offload split to this runtime.
    private var modelPresent: Bool {
        (api.status == .ok && api.primaryModel != nil) || runtime.primaryMemoryBytes > (1 << 30)
    }

    var body: some View {
        Card(title: "AI Runtime") {
            VStack(alignment: .leading, spacing: 4) {
                header
                if modelPresent { engineLine }
                modelLine
                budgetLine
                benchmarkLine
            }
        }
    }

    // On-demand speed benchmark — only when the runtime API is on with a loaded model
    // (that's how we know the model name + have an endpoint to generate against).
    @ViewBuilder private var benchmarkLine: some View {
        if allowBenchmark, api.status == .ok, api.primaryModel != nil {
            HStack(spacing: 6) {
                if isBenchmarking {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("measuring tok/s…")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                } else if let b = benchmark {
                    Image(systemName: "bolt.fill").font(.system(size: 9.5)).foregroundStyle(Theme.heat(0.3))
                    Text(String(format: "%.1f tok/s", b.tokensPerSec))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(String(format: "· %.0f tok/Wh", b.tokensPerWattHour))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                    Button("re-measure", action: onBenchmark)
                        .font(.system(size: 10, design: .monospaced)).buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                } else {
                    Button(action: onBenchmark) {
                        Label("Measure tok/s", systemImage: "bolt")
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            if let e = benchmarkError {
                Text(e).font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.heat(0.7)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if runtime.isActive, let kind = runtime.primaryKind {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol).font(.system(size: 11)).foregroundStyle(kind.color)
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(String(format: "RAM %.1f GB · CPU %.0f%%",
                            Double(runtime.primaryMemoryBytes) / Self.gb, runtime.cpuPercent(of: kind)))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                if let port = runtime.ollamaEmbeddedPort {
                    Text(":\(port)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text("No local AI runtime detected")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            }
        }
    }

    // Model PLACEMENT (where the model runs) — not GPU utilization, which the GPU card
    // already shows. ③ gives the authoritative GPU/CPU offload split; otherwise an
    // engine-type hint (no GPU% here, to avoid duplicating the GPU card).
    @ViewBuilder private var engineLine: some View {
        if api.isReachable, let split = api.primaryModel?.processorLabel {
            HStack(spacing: 6) {
                Text("Offload").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                Text(split).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                Text("Engine").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                Text(likelyEngine).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if cpuOffloadLikely {
                    Text("· likely CPU offload (est.)")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.heat(0.7))
                }
                Spacer(minLength: 0)
            }
        }
    }

    // ③ model line: authoritative loaded-model info + tokens/sec, or a status hint.
    @ViewBuilder private var modelLine: some View {
        if api.status == .ok, let m = api.primaryModel {
            HStack(spacing: 6) {
                Image(systemName: "cube.fill").font(.system(size: 9.5)).foregroundStyle(Theme.accent)
                Text(m.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(modelDetail(m)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                if let tps = api.tokensPerSec {
                    Text(String(format: "· %.0f tok/s", tps))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.heat(0.4))
                }
                Spacer(minLength: 0)
            }
        } else if runtime.isActive {
            // Only annotate API status when a runtime was actually detected — with none,
            // the header already says "No local AI runtime detected" (avoid redundancy).
            switch api.status {
            case .ok:
                runtimeNote(likelyEngine.hasPrefix("GPU active")
                    ? "runtime idle — GPU load is from another app (in-app / unmanaged)"
                    : "runtime running — no model loaded")
            case .runningNoServer:  runtimeNote("runtime running — start its local server for model + tok/s")
            case .apiNotApplicable: runtimeNote("CLI runtime — no local API")
            case .unreachable:      runtimeNote("runtime API unreachable")
            case .disabled:         runtimeNote("Enable “Connect to local AI runtimes” in Settings for model + tok/s")
            }
        }
    }

    private func runtimeNote(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func modelDetail(_ m: RuntimeModelInfo) -> String {
        var parts: [String] = []
        if let p = m.parameterSize { parts.append(p) }
        if let q = m.quantization { parts.append(q) }
        if m.sizeBytes > 0 { parts.append(String(format: "%.1f GB", m.sizeGB)) }
        if let ctx = m.contextLength, ctx > 0 { parts.append("\(ctx / 1024)k ctx") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }

    private var budgetLine: some View {
        HStack(spacing: 8) {
            Text("Model budget").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            Text(budgetText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if memoryRisk != .ok {
                Text(memoryRisk.label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(memoryRisk.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(memoryRisk.color.opacity(0.15), in: Capsule())
            }
        }
    }

    private var budgetText: String {
        let nowB = budget.fitsNow.first.map { String(format: "%.0fB", $0.maxParamsBillions) } ?? "—"
        // A resident model is taking meaningful RSS ⇒ show both scenarios; else one value.
        let hasResidentModel = budget.loadableBytes > budget.headroomNowBytes + (1 << 30)
        if hasResidentModel, let load = budget.fitsLoadable.first {
            let loadB = String(format: "%.0fB", load.maxParamsBillions)
            return "+\(nowB) alongside · ~\(loadB) if you unload \(residentModelName) (Q4_K_M)"
        }
        return "largest model ~\(nowB) (Q4_K_M)"
    }

    private var residentModelName: String {
        if let name = api.primaryModel?.name { return name }
        if let kind = runtime.primaryKind { return "\(kind.displayName) model" }
        return "current model"
    }
}

// MARK: - Compute cards

private struct CPUCard: View {
    let cpu: CPUSample
    let topology: CPUTopology?
    let eHistory: [Double]
    let pHistory: [Double]
    let throttling: Bool             // cpuThrottling: P-cluster held below its DVFS ceiling under thermal pressure
    let clockDrop: Double            // cpuClockDropFraction: how far the P-clock sits below the chip's top step
    @AppStorage("menubar.cpu") private var cpuMB = false

    private let eColor = Color(nsColor: MetricPalette.eCPU)   // amber
    private let pColor = Color(nsColor: MetricPalette.pCPU)   // blue
    private let alertColor = Color(red: 0.88, green: 0.37, blue: 0.37)

    private var pMaxMHz: Double { topology?.pFreqsMHz.max() ?? 0 }

    var body: some View {
        // When the P-cluster is thermally throttled: a red card border (consistent with the GPU card's
        // throttle treatment) flags it, and a dim "P ceiling" line states the fact — clock vs the chip's
        // DVFS ceiling. Border = salience, line = the instrument reading.
        Card(title: "CPU", menuBarPin: $cpuMB, alert: throttling ? alertColor : nil) {
            Bar(label: "E-cores", value: cpu.eUsage,
                detail: String(format: "%.0f%%  %.0f MHz", cpu.eUsagePercent, cpu.eFreqMHz), color: eColor)
            Bar(label: "P-cores", value: cpu.pUsage,
                detail: String(format: "%.0f%%  %.0f MHz", cpu.pUsagePercent, cpu.pFreqMHz), color: pColor)

            if throttling {
                Bar(label: "P ceiling", value: pMaxMHz > 0 ? cpu.pFreqMHz / pMaxMHz : 0,
                    detail: String(format: "%.0f / %.0f MHz · −%.0f%% (thermal)",
                                   cpu.pFreqMHz, pMaxMHz, clockDrop * 100),
                    color: Theme.dim)
            }
        } graph: {
            ZStack {
                Sparkline(values: eHistory, color: eColor, yDomain: 0...1, fill: true, grid: true)
                Sparkline(values: pHistory, color: pColor, yDomain: 0...1, fill: true)
            }
        }
    }
}

private struct AcceleratorCard: View {
    let gpu: GPUSample
    let power: PowerSample
    let bandwidth: BandwidthSample
    let anePeak: Double
    let mediaPeak: Double
    let gpuHistory: [Double]
    let gpuMemHistory: [Double]
    let mediaHistory: [Double]
    let aneHistory: [Double]
    let throttling: Bool                            // #18: red card border while the GPU is thermally throttled
    @AppStorage("menubar.gpu") private var gpuMB = false

    private let gpuColor = MetricPalette.gpuC       // green
    private let memColor = MetricPalette.gpuMemC    // sky cyan — GPU memory
    private let mediaColor = MetricPalette.mediaC   // orange
    private let aneColor = MetricPalette.aneC       // purple

    var body: some View {
        Card(title: "GPU / Media / Neural Engine", menuBarPin: $gpuMB,
             alert: throttling ? Color(red: 0.88, green: 0.37, blue: 0.37) : nil) {
            Bar(label: "GPU", value: gpu.usage,
                detail: String(format: "%.0f%%  %.1f W  %.0f MHz", gpu.usagePercent, power.gpuWatts, gpu.freqMHz),
                color: gpuColor)
            Bar(label: "GPU memory", value: gpu.inUseMemoryFraction,
                detail: String(format: "%.1f GB in use", gpu.inUseMemoryGB), color: memColor)
            Bar(label: "ANE est.", value: min(1, power.aneWatts / max(anePeak, 0.1)),
                detail: String(format: "%.1f W", power.aneWatts), color: aneColor)
            Bar(label: "Media", value: min(1, bandwidth.mediaGBs / max(mediaPeak, 0.5)),
                detail: String(format: "%.1f GB/s", bandwidth.mediaGBs), color: mediaColor)
        } graph: {
            ZStack {
                Sparkline(values: gpuHistory, color: gpuColor, yDomain: 0...1, fill: true, grid: true)
                Sparkline(values: gpuMemHistory, color: memColor, yDomain: 0...1, fill: true)
                Sparkline(values: aneHistory.map { min(1, $0 / max(anePeak, 0.1)) },
                          color: aneColor, yDomain: 0...1, fill: true)
                Sparkline(values: mediaHistory.map { min(1, $0 / max(mediaPeak, 0.5)) },
                          color: mediaColor, yDomain: 0...1, fill: true)
            }
        }
    }
}

// MARK: - Memory & Bandwidth (split)

private struct MemoryBandwidthCard: View {
    let memory: MemorySample
    let bandwidth: BandwidthSample
    let bandwidthPeak: Double
    let memHistory: [Double]
    let bwHistory: [Double]
    @AppStorage("menubar.mem") private var memMB = false

    private let wiredColor = Color(red: 0.36, green: 0.62, blue: 0.98)
    private let activeColor = Color(red: 0.34, green: 0.74, blue: 0.62)
    private let compressedColor = Color(red: 0.62, green: 0.55, blue: 0.95)
    private let freeColor = Color.white.opacity(0.10)

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal:   return Color(red: 0.34, green: 0.74, blue: 0.49)
        case .warning:  return Color(red: 0.87, green: 0.66, blue: 0.28)
        case .critical: return Color(red: 0.88, green: 0.37, blue: 0.37)
        }
    }

    // #18: nil when nominal → normal border; amber (elevated) / red (critical) tints the card border
    // so the user sees which metric is under pressure without relying on the (dismissable) banner.
    private var alertColor: Color? {
        switch memory.pressure {
        case .normal:   return nil
        case .warning:  return Color(red: 0.87, green: 0.66, blue: 0.28)
        case .critical: return Color(red: 0.88, green: 0.37, blue: 0.37)
        }
    }

    var body: some View {
        Card(title: "Memory & Bandwidth", alert: alertColor) {
            HStack(alignment: .top, spacing: 10) {
                memorySection.frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Theme.border)
                bandwidthSection
            }
            .frame(maxHeight: .infinity)   // fill the card so the bandwidth column can pin its graph to the bottom
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SubLabel("Memory", menuBarPin: $memMB)
            HStack {
                Text(String(format: "%.1f / %.0f GB", memory.usedGB, memory.totalGB))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text(String(format: "%.0f%%", memory.usedPercent))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            StackedBar(segments: [
                (memory.wiredFraction, wiredColor),
                (memory.activeFraction, activeColor),
                (memory.compressedFraction, compressedColor),
                (memory.freeFraction, freeColor),
            ])
            LegendRow(color: wiredColor, key: "Wired", value: String(format: "%.1f GB", memory.wiredGB))
            LegendRow(color: activeColor, key: "Active", value: String(format: "%.1f GB", memory.activeGB))
            LegendRow(color: compressedColor, key: "Compressed", value: String(format: "%.1f GB", memory.compressedGB))
            LegendRow(color: freeColor, key: "Free", value: String(format: "%.1f GB", memory.freeGB))
            HStack {
                Text("Pressure").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.0f%%", memory.pressurePercent))
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(pressureColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(pressureColor)
                        .frame(width: max(2, geo.size.width * min(1, memory.pressurePercent / 100)))
                }
            }.frame(height: 4)
            KV(key: "App Memory", value: String(format: "%.1f GB", memory.appMemoryGB))
            KV(key: "Cached", value: String(format: "%.1f GB", memory.cachedFilesGB))
            KV(key: "Swap", value: String(format: "%.1f GB", memory.swapUsedGB))
        }
    }

    private var bandwidthSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SubLabel("Bandwidth")
            Bar(label: "Total", value: min(1, bandwidth.totalGBs / max(bandwidthPeak, 1)),
                detail: String(format: "%.0f GB/s", bandwidth.totalGBs))
            KV(key: "CPU", value: String(format: "%.0f GB/s", bandwidth.cpuGBs))
            KV(key: "GPU", value: String(format: "%.0f GB/s", bandwidth.gpuGBs))
            KV(key: "Media", value: String(format: "%.0f GB/s", bandwidth.mediaGBs))
            KV(key: "Other", value: String(format: "%.0f GB/s", bandwidth.otherGBs))
            Spacer(minLength: 4)
            // #20: the dense Memory column has no room for its own trend, so the memory-used
            // sparkline shares this (sparser) column's spare space — labelled, stacked with
            // bandwidth-over-time (same pattern as the Network & Disk card's two graphs). Memory is
            // scaled to total RAM (0...totalGB, a near-constant series); bandwidth auto-scales (GB/s).
            VStack(alignment: .leading, spacing: 10) {
                LabeledSparkline(label: "BW", values: bwHistory,
                                 color: Color(red: 0.42, green: 0.66, blue: 0.95))
                LabeledSparkline(label: "Mem", values: memHistory,
                                 color: Color(red: 0.66, green: 0.60, blue: 0.96),
                                 yDomain: 0...max(memory.totalGB, 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A trend sparkline with a compact leading label — for columns where two series share the space
/// and color alone doesn't identify them (Memory vs Bandwidth in the Memory & Bandwidth card).
private struct LabeledSparkline: View {
    let label: String
    let values: [Double]
    let color: Color
    var height: CGFloat = 18
    var yDomain: ClosedRange<Double>? = nil
    var body: some View {
        // Label sits ABOVE the trend (not overlaid on the line) so it stays readable regardless of
        // where the line happens to be.
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(color.opacity(0.9))
            Sparkline(values: values, color: color, height: height, yDomain: yDomain)
        }
    }
}

// MARK: - Network & Disk (split)

private struct NetworkDiskCard: View {
    let network: NetworkSample
    let disk: DiskSample
    let downHistory: [Double]
    let upHistory: [Double]
    let readHistory: [Double]
    let writeHistory: [Double]

    @AppStorage("menubar.net") private var netMB = false
    @AppStorage("menubar.ssd") private var ssdMB = false
    private let downColor = Color(red: 0.34, green: 0.74, blue: 0.62)
    private let upColor = Color(red: 0.95, green: 0.62, blue: 0.30)

    var body: some View {
        Card(title: "Network & Disk") {
            HStack(alignment: .top, spacing: 10) {
                networkSection.frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Theme.border)
                diskSection.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SubLabel("Network", menuBarPin: $netMB)
            KV(key: "↓ Download", value: formatRate(network.downloadBytesPerSec), valueColor: downColor)
            KV(key: "↑ Upload", value: formatRate(network.uploadBytesPerSec), valueColor: upColor)
            Spacer(minLength: 4)
            Sparkline(values: downHistory, color: downColor, height: 22)
            Sparkline(values: upHistory, color: upColor, height: 22)
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SubLabel("Disk", menuBarPin: $ssdMB)
            KV(key: "Read", value: formatRate(disk.readBytesPerSec), valueColor: downColor)
            KV(key: "Write", value: formatRate(disk.writeBytesPerSec), valueColor: upColor)
            Bar(label: "Used", value: disk.usedFraction,
                detail: "free \(formatBytes(disk.freeBytes)) / \(formatBytes(disk.totalBytes))")
            Spacer(minLength: 4)
            Sparkline(values: readHistory, color: downColor, height: 22)
            Sparkline(values: writeHistory, color: upColor, height: 22)
        }
    }
}

private struct SubLabel: View {
    let text: String
    var menuBarPin: Binding<Bool>? = nil
    init(_ text: String, menuBarPin: Binding<Bool>? = nil) { self.text = text; self.menuBarPin = menuBarPin }
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundStyle(Theme.faint)
            if let pin = menuBarPin { MenuBarPin(isOn: pin) }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sensors (fans/pressure + accordion)

private struct SensorsCard: View {
    let temperature: TemperatureSample
    let thermal: ThermalSample
    @AppStorage("temperatureFahrenheit") private var fahrenheit = false
    @AppStorage("menubar.sensors") private var sensorsMB = false

    private var pressureColor: Color {
        switch thermal.pressure {
        case .nominal: return Theme.heat(0.2)
        case .fair: return Theme.heat(0.65)
        case .serious, .critical: return Theme.heat(1.0)
        default: return Theme.dim
        }
    }

    var body: some View {
        Card(title: "Sensors", menuBarPin: $sensorsMB) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("Pressure").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                        Text(thermal.pressure.rawValue)
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(pressureColor)
                    }
                    HStack(spacing: 6) {
                        Text("Fans").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                        Text(thermal.hasFans
                            ? thermal.fanRPMs.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " rpm"
                            : "fanless")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
                Divider().overlay(Theme.border)
                if temperature.groups.isEmpty {
                    Text("no sensors available")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(temperature.groups) { group in
                                SensorGroupRow(group: group, fahrenheit: fahrenheit)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

private struct SensorGroupRow: View {
    let group: SensorGroup
    let fahrenheit: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                ForEach(group.sensors) { sensor in
                    HStack(spacing: 6) {
                        Text(sensor.name).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(formatTemperature(sensor.celsius, fahrenheit: fahrenheit))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.heat(min(1, sensor.celsius / 100)))
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(group.category.rawValue)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                Text("(\(group.count))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faint)
                Spacer()
                Text("avg \(formatTemperature(group.average, fahrenheit: fahrenheit)) · max \(formatTemperature(group.maximum, fahrenheit: fahrenheit))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.heat(min(1, group.maximum / 100)))
            }
        }
        .tint(Theme.dim)
    }
}

// MARK: - Processes (interactive)

private struct ProcessCard: View {
    let processes: [ProcessRow]
    var allowKill = true            // false during replay — recorded PIDs are stale (would kill live)
    var onInspect: ((ProcessRow) -> Void)? = nil   // tap / "Inspect" → focus this process

    enum SortKey { case cpu, memory, name }
    @State private var sortKey: SortKey = .cpu
    @State private var filter: String = ""
    @State private var pendingKill: ProcessRow?
    @State private var pendingForce = false
    @State private var hoveredPID: Int32?   // row under the cursor → reveal its Quit affordance

    private var rows: [ProcessRow] {
        // `processes` already arrives sorted by CPU% desc (ProcessSampler pre-sorts; recorded
        // .ssrec rows preserve that order), so the default CPU view skips a redundant re-sort.
        if sortKey == .cpu, filter.isEmpty { return Array(processes.prefix(200)) }
        let base = filter.isEmpty
            ? processes
            : processes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let sorted: [ProcessRow]
        switch sortKey {
        case .cpu:    sorted = base.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: sorted = base.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name:   sorted = base.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
        return Array(sorted.prefix(200))
    }

    var body: some View {
        Card(title: "Processes") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    TextField("Filter by name", text: $filter)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    } else if onInspect != nil {
                        Text("tap to inspect")
                            .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Text("PID").frame(width: 56, alignment: .leading)
                    header("CPU%", .cpu).frame(width: 60, alignment: .trailing)
                    header("MEMORY", .memory).frame(width: 84, alignment: .trailing)
                    header("NAME", .name).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { process in
                            HStack {
                                Text("\(process.pid)").frame(width: 56, alignment: .leading).foregroundStyle(Theme.faint)
                                Text(String(format: "%.1f", process.cpuPercent))
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundStyle(Theme.heat(min(1, process.cpuPercent / 100)))
                                Text(String(format: "%.0f MB", process.memoryMB))
                                    .frame(width: 84, alignment: .trailing).foregroundStyle(Theme.dim)
                                Text(process.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                // Trailing Quit affordance — reveals on row hover so the (already
                                // existing) kill is discoverable without cluttering the table. Sends
                                // SIGTERM via the shared confirm dialog; Force Quit stays in the menu.
                                Group {
                                    if allowKill && hoveredPID == process.pid {
                                        Button { pendingKill = process; pendingForce = false } label: {
                                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                                                .foregroundStyle(Color(red: 0.88, green: 0.37, blue: 0.37))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Kill \(process.name)")
                                    }
                                }
                                .frame(width: 16)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .contentShape(Rectangle())
                            .onTapGesture { onInspect?(process) }
                            .onHover { hovering in
                                if hovering { hoveredPID = process.pid }
                                else if hoveredPID == process.pid { hoveredPID = nil }
                            }
                            .contextMenu {
                                if let onInspect {
                                    Button("Inspect \(process.name)") { onInspect(process) }
                                }
                                if allowKill {
                                    Button("Kill \(process.name)") { pendingKill = process; pendingForce = false }
                                    Button("Force Kill \(process.name)", role: .destructive) {
                                        pendingKill = process; pendingForce = true
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            pendingKill.map { "\(pendingForce ? "Force kill" : "Kill") \($0.name)  (pid \($0.pid))?" } ?? "",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingForce ? "Force Kill" : "Kill", role: .destructive) {
                if let process = pendingKill {
                    if pendingForce { ProcessControl.forceKill(pid: process.pid) }
                    else { ProcessControl.terminate(pid: process.pid) }
                }
                pendingKill = nil
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        }
    }

    @ViewBuilder private func header(_ title: String, _ key: SortKey) -> some View {
        Button { sortKey = key } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key { Image(systemName: "chevron.down").font(.system(size: 7)) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(sortKey == key ? Theme.accent : Theme.faint)
    }
}
