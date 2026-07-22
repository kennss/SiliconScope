# SiliconScope — Remote & Fleet Monitoring

> **Status: SHIPPED in v4.0.0 (2026-07-23).** Sections 1–4 and 6–7 held up and still describe the
> feature. Sections 5, 8 and 9 were written as a proposal and the build diverged from them — see
> **§0 As shipped** for what actually exists and why it differs. The original text is kept below as
> the decision record, not as documentation of the current system.
> **Author:** Kennt Kim / Calida Lab · **Created:** 2026-07-14 · **Updated:** 2026-07-23
> Watch a *headless* Apple-Silicon box (e.g. a Mac mini running local LLMs) from the full
> SiliconScope GUI on another Mac — by running a lightweight agent on the remote host and
> pulling its metrics over the LAN. Turns SiliconScope from "monitor *this* Mac" into
> "monitor my Apple-Silicon *fleet*."

---

## 0. As shipped (v4.0.0)

**What exists:** two agents and a fleet UI.

- **Linux agent** — `agent/` (Go, static, no deps): reads `/proc` + `nvidia-smi`, detects Ollama.
  Installed as a hardened **systemd** service by `scripts/install-agent.sh`.
- **Mac agent** — `sscope-agent-mac` (Swift, reuses `SiliconScopeCore`): installed under
  `~/.local/bin` as a **LaunchAgent** with **no sudo**. The app itself can serve instead, via
  **Settings → Share this Mac** (`MacAgentController`).
- **Viewer** — a unified **Devices sidebar** (This Mac + every agent) plus a **Fleet overview grid**,
  in the single main window.

**Where it diverged from the proposal — and why:**

| §5 proposed | Shipped | Why |
|---|---|---|
| One agent: `sscope --serve` (the Swift CLI) | **Two** agents (Go for Linux, Swift for Mac) | Linux became a first-class target; a static Go binary drops all runtime deps on a GPU box. |
| Homebrew **formula** for the agent | `curl \| sh` → systemd / LaunchAgent | Agents belong to the machine's service manager, and this works identically on Linux. |
| Apple-Silicon fleet only | **Linux/NVIDIA is a first-class `kind`** with its own GPU-centric view | The real fleet these users have is Macs *and* GPU boxes. Rendering a 3090 in a Mac layout was tried and was wrong (no E/P cores, no ANE). |
| TLS "ideally", token required | **TLS mandatory + bearer token + TOFU cert pin** | A metrics daemon on the network earns no benefit of the doubt (§6). |
| Bonjour "nice-to-have, not v1" | **mDNS discovery is the default path in v1** | Removing IP configuration is most of the UX win; typing a host is now the *fallback*. |
| v1 = "Add Remote Host" → a second window; fleet sidebar later | **Unified sidebar + overview grid directly**; no second window | A second window fragments the app; one window with a device list is simpler and scaled to N machines immediately. |
| Negotiated protocol/schema version | **No negotiation** — schema evolves by adding `Optional` fields | Simpler and sufficient: an older agent's payload still decodes, and the viewer falls back per field. |
| Remote view is "full fidelity", so Replay / Inspector / menu-bar work for free | **A curated wire schema** (`MachineMetrics`), and remote mode hides what it can't fill | The remote source is **not** a full `Snapshot`. Per-process ANE memory, per-sensor temperature lists, network/disk and the process table are not transmitted; Replay and Inspector remain local-only. Rather than fake them, the remote dashboard omits those cards. |

**Wire boundary.** `MachineMetrics` (Core) is the contract — deliberately source-agnostic so the Go
and Swift agents produce the same JSON. `MachineMetrics.mac()` encodes it; `toDashboardSnapshot()`
synthesizes a `SystemSnapshot` so a remote Mac reuses the *local* `DashboardView` unchanged.

**Pairing.** Installers print one `sscope://pair?name=…&host=…&port=…&token=…` link
(`PairingLink`, Core — it owns both encode and decode so the printed and parsed formats can't
drift). Pasting it into **Add machine…** adds and pairs in one step. The token is keyed by the
machine's **name**, which is why renaming a machine requires re-pairing.

**Known limits (documented, not hidden):** GPU data on Linux requires `nvidia-smi`; remote Sensors
says "no sensors available" rather than inventing values; mDNS doesn't traverse subnets, so
Tailscale/VPN/cloud machines are added by address.

---

## 1. Problem / motivation

The originating scenario:

- My **MacBook** runs SiliconScope (GUI).
- A separate **Mac mini** runs the actual AI workload (local LLMs / inference server).
- **Today I can't see the mini's silicon** — its ANE / GPU / memory-bandwidth / power /
  per-process load are invisible from the laptop. I'd have to sit at the mini, or SSH in
  and squint at raw tools.

This is exactly the box you *most* want to watch (it's the one doing the AI work), and it's
the one SiliconScope currently can't reach. Dedicated Apple-Silicon inference boxes
(Mac minis / Studios as always-on LLM servers, often headless in a homelab/rack) are a real
and growing pattern.

## 2. The idea, in one line

> Install a **headless agent** on the Mac mini that samples its metrics with
> `SiliconScopeCore` and serves them over the LAN; the MacBook's SiliconScope opens a
> **second view fed by that remote source** — the *same* dashboard, showing the mini.

## 3. Why this beats the alternatives

We circled a terminal/TUI answer for headless monitoring (a `btop`-style TUI over SSH, or
forking btop). Remote-agent + GUI is a **better answer to the same need**:

| Approach | Headless box? | Viewing experience | Data layer |
|---|---|---|---|
| SSH + TUI | ✅ | terminal, cramped | needs a whole TUI renderer |
| Fork btop | ✅ | btop look | **re-port the Apple-Silicon core to C++ + maintain twice** ❌ |
| **Remote agent + GUI** | ✅ | **full native GUI, per-process ANE and all** | **reuses `SiliconScopeCore` as-is** ✅ |

The remote-agent path solves headless monitoring with a *superior* UX (the full dashboard,
not a terminal) **and** keeps one Swift data layer. It makes the TUI / btop-fork questions
moot for this use case.

## 4. Architectural key — we already built the hard part (the Replay seam)

The dashboard renders from a **`Snapshot`** (all metrics for one moment). **Record & Replay
already decoupled the dashboard from the live local sampler**: Replay drives the exact same
UI from snapshots read out of an `.ssrec` file instead of live sampling.

Remote monitoring is just a **third snapshot source on the seam we already have**:

```
                 ┌───────────────────────────────┐
 local sampler ──┤                               │
 .ssrec file  ───┤   SnapshotSource  ──────────► │  Dashboard (unchanged)
 remote agent ───┤   (local | replay | remote)   │
                 └───────────────────────────────┘
```

The GUI does not care where a `Snapshot` came from. So the expensive work — *decoupling the
UI from the live local sampler* — is **already done for Replay**. Remote is a new source
that fills the same `Snapshot`, which makes this far cheaper than it looks.

**Action item:** formalize a `SnapshotSource` abstraction (if not already explicit) with
three conformers: `LiveSampler`, `ReplaySource` (existing `.ssrec` path), `RemoteSource`
(new, network).

## 5. Components

### 5.1 Agent — `sscope --serve` (on the remote host)

- **Is the CLI work.** The proposed `sscope` CLI (`--json` / `--watch`) gains a `--serve`
  mode: run `SiliconScopeCore`, sample continuously, expose snapshots over the network.
  Doing the CLI is therefore **half of this feature**, not a detour.
- Runs headless (no GUI, no `sudo`). Lightweight — the core is already sudoless and cheap; a
  monitor must never disturb the workload it watches.
- Ships as a **Homebrew _formula_** (`brew install sscope-agent` on the mini) — no
  notarization, easier acceptance, far more `brew install` reach than the GUI cask.
- Because the *real* core runs on the mini, the remote view is **full fidelity** — including
  **per-process ANE memory** (SiliconScope's unique signal). You see the mini's ANE-per-
  process from the couch, not a degraded summary.

### 5.2 Transport & protocol

- **Snapshot schema:** the same `Snapshot` the core already produces, serialized.
- **Options:**
  - JSON over **HTTP** (`GET /snapshot`) or **SSE / WebSocket** stream — simplest,
    inspectable, firewall-friendly.
  - Or a compact **binary protocol over TCP** — smaller/faster for high-rate streaming.
  - Start with JSON-over-HTTP/SSE; optimize later only if rate demands it.
- **Discovery:** **Bonjour / mDNS** so the mini simply *appears* ("SiliconScope found a
  Mac mini on your network"). Nice-to-have, not v1.
- **Versioning:** negotiate a **protocol/schema version** between agent and viewer to
  survive skew (agent and viewer will update independently).

### 5.3 GUI consumer (on the MacBook)

- **v1:** "Add Remote Host" (host:port + token) → opens a **new window** fed by a
  `RemoteSource`. Identical dashboard, driven by the mini's snapshots. (This matches the
  original "just open one more SScope" instinct.)
- **later:** a **fleet sidebar** — local + N remote hosts in one app, switch or tile them.
- Replay, Inspector, per-metric menu-bar items — all work on a remote source for free,
  because they already consume `Snapshot`s.

## 6. Security model (load-bearing — this is a metrics daemon on the network)

SiliconScope's DNA is privacy / on-device. The agent must not betray that:

- **Opt-in only.** Serving is off by default; the user explicitly enables it.
- **LAN-scoped.** Bind to the local network / a chosen interface; never expose to the
  public internet by default.
- **Authenticated.** A shared **token** (pairing code) required; reject unauthenticated
  pulls. Ideally **TLS** for the transport.
- **Nothing leaves the LAN.** Agent → viewer is a direct local connection; **zero cloud
  relay, zero telemetry.** This constraint is itself a selling point for the target
  audience.

## 7. Strategic positioning

- **Product vision grows:** "monitor *this* Mac" → **"monitor my Apple-Silicon fleet."**
- **Bull's-eye on the origin DNA:** SiliconScope was born from wanting to *see* how on-device
  AI drives the silicon. A dedicated Mac mini running LLMs is precisely that workload —
  the same thread as SpectaLing using SiliconScope to catch WhisperKit ANE stalls.
- **Perfect audience fit:** the **r/LocalLLaMA / homelab** crowd running Mac minis & Studios
  as inference servers — exactly the people who star repos on GitHub and live on HN.
- **Nobody else does this:** iStat Menus, asitop, btop cannot show a *remote* Apple-Silicon
  box's ANE / Media / bandwidth in a full GUI. Clear differentiation → strong star magnet.

## 8. Phased roadmap

> **Superseded.** The phases collapsed: v4.0.0 shipped all four at once. Phase 1 (`sscope-cli`)
> already existed; phase 2 became *two* agents rather than `sscope --serve`; phase 3's second-window
> `RemoteSource` was skipped entirely; phase 4 (Bonjour + fleet sidebar), which was to be "gated on
> traction", turned out to be the part that makes the feature usable and shipped in v1. See §0.


1. **`sscope` CLI** (`--json` / `--watch` / `--once`) — reuses the core; opens the Homebrew
   **formula** channel. Low-risk probe of the terminal/headless audience.
2. **`sscope --serve`** — the agent: same CLI + network transport (JSON/SSE) + token auth.
3. **GUI `RemoteSource`** — "Add Remote Host" → new window, on the existing Replay seam.
4. **Bonjour discovery** + **fleet sidebar** (multi-host) — gate on traction.

Each phase ships value on its own; the sequence reuses the core at every step and never
forks the data layer.

## 9. Open questions / risks

> **Resolved in v4.0.0:** *schema versioning* — no negotiation; `Optional` fields keep old agents
> decodable. *Sampling overhead* — the Go agent reads `/proc`; the Mac agent reuses the same 1 Hz
> Core sampler as the GUI. *Multi-host UX* — solved directly with the sidebar + overview grid rather
> than deferred. *Security surface* — TLS + bearer token + TOFU cert pin.
> **Still open:** *connection resilience* is only partial — a dead agent surfaces as a per-machine
> error and launchd/systemd restart it, but there's no backoff/staleness badge beyond the
> "updated …" timestamp. Clock skew is moot for now (Replay stays local). New since: pairing is
> keyed by machine **name**, so a rename breaks it — keying by the stable `machineId` would fix it,
> but the viewer can't read that until it's already authenticated.


- **Protocol/schema versioning** across independently-updated agent & viewer.
- **Sampling overhead** on the remote host — keep the agent as light as the local sampler;
  a monitor that steals cycles from the workload is self-defeating.
- **Multi-host UX** — start with the second-window model; the fleet sidebar is a bigger
  design problem (layout, per-host alerts, naming) — defer until asked for.
- **Security surface** — a networked metrics daemon must be locked down (see §6); treat
  this as a first-class requirement, not an afterthought.
- **Connection resilience** — reconnect, staleness indicator when the agent drops, clock
  skew between hosts (relevant for Replay of a remote session).

## 10. Relationship to existing code

- **Record & Replay** (`ReplayController`, `.ssrec`) — proves the dashboard can run off a
  non-live snapshot source. This is the enabling architecture; remote is the third source.
- **`sscope-cli`** — already dumps every metric to the terminal (topology, power, bandwidth,
  per-process, AI runtimes, `--bench`). The agent is this CLI plus a `--serve` transport.
- **`SiliconScopeCore`** — the UI-independent Swift data layer; runs unchanged on the remote
  host. One source of truth for local, replay, and remote. A single macOS-version fix (e.g.
  the macOS 27 bandwidth-channel rename, issue #14) flows to GUI + CLI + agent at once.
