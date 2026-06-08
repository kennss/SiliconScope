# WhisPlayInfo — Display Spec

> What WhisPlayInfo shows and why. Derived from analysis of btop / NeoAsitop / iStat
> Menus plus the on-device-AI trend. All in-app labels are English (the names in the
> tables below are the actual UI labels).

---

## 0. Core insight — "where does an AI workload actually run?"

Tracing today's growing workloads makes the differentiator clear:

| Workload | Engine actually used | Bottleneck |
|---|---|---|
| **Local LLM** (llama.cpp / MLX / Ollama) | **Metal GPU + unified memory** (ANE *not* used) | **memory bandwidth** (esp. 27B+) |
| **AI photo/video, Siri, classification** (CoreML) | **ANE** (+ some GPU) | ANE throughput / power & heat |
| Large resident model | unified-memory capacity | **memory pressure / swap** |

**Design principles**

1. Put **GPU + memory bandwidth + memory pressure** front and center — what LLM users actually care about.
2. **ANE is a "which engine is working" signal** — for an LLM only the GPU lights up while ANE stays idle; a CoreML app lights up ANE. That contrast is the insight.
3. **Thermals/throttle + sustained power** — AI is a sustained load, so throttling governs real performance.
4. Because memory is unified, surface **wired** memory (Metal/GPU allocations) separately.

> ⚠️ ANE "utilization" is a power-based estimate (Apple exposes no true figure). Labelled `est.` in the UI.

---

## 1. Tool comparison — what each surfaces

| Item | btop | NeoAsitop | iStat Menus | **WhisPlayInfo** |
|---|---|---|---|---|
| Per-core CPU | ✓ | ✗ (E/P aggregate only) | ✓ | ✓ |
| **E/P core split** | ✗ | ✓ | ✓ (freq) | **✓✓ core feature** |
| GPU usage/freq | Linux only | ✓ | ✓ | ✓ |
| **ANE** | ✗ | ✓ | ✗ | **✓ differentiator** |
| **Memory bandwidth** | ✗ | ✓ (E/P/GPU/Media) | ✗ | **✓✓ differentiator** |
| Memory pressure | ✗ | ✗ | ✓ | **✓** |
| Wired/compressed/swap | swap only | ✗ | ✓ | ✓ |
| Power (per domain) | ✗ | ✓ (CPU/GPU/sys/RAM) | ✓ | ✓ |
| Thermal / throttle | temp | ✗ | sensors | ✓ |
| Fans | limited | ✓ | ✓✓ | ✓ |
| Processes (top/tree/kill) | ✓✓ | ✗ | top apps | ✓ |
| Disk / Network | ✓ | ✗ | ✓✓ | ✓ |
| Battery | basic | ✗ | ✓✓ | ✓ |
| Alerts | ✗ | ✗ | ✓ | ✓ (memory pressure, bandwidth-bound) |

**Read:** NeoAsitop = strong chip metrics (plain UI) / iStat = broad (weak on AI; no ANE/bandwidth) / btop = strong processes & UX (thin on Apple Silicon).
→ **WhisPlayInfo = NeoAsitop's chip metrics + iStat's memory-pressure/thermal breadth + btop's process/UX**, plus an AI-workload lens.

---

## 2. Information set

All data sources are sudoless (see `ioreport-channels.md`).

### Apple Silicon / AI signature (the differentiators)

| In-app label | Content | Source |
|---|---|---|
| `E-cores` / `P-cores` | per-cluster usage % + frequency | host_processor_info (usage) + IOReport CPU Stats × DVFS (freq) |
| `GPU` | usage %, frequency, power | IOReport GPU Stats + Energy Model |
| `ANE (est.)` | power-based activity + "engine in use" hint | IOReport Energy Model |
| `Memory Bandwidth` | CPU / GPU / Media / total GB/s | IOReport AMC Stats |
| `Memory pressure` | normal / elevated / critical + wired/compressed/swap | host_statistics64 + sysctl |
| `Power` | CPU / GPU / ANE / DRAM / SoC W | IOReport Energy Model |
| `Thermal` | thermal pressure, fans, die temps | ProcessInfo + SMC |

### Core system (parity)

| In-app label | Content | Source |
|---|---|---|
| `Memory` | wired / active / compressed / free, swap | vm_statistics64 |
| `Temperatures` | grouped CPU / GPU / Memory / Battery °C | SMC |
| `Fans` | RPM (fanless models handled) | SMC |
| `Network` | download / upload | getifaddrs |
| `Disk` | read / write + capacity | IOBlockStorageDriver + volume capacity |
| `Processes` | top by CPU/MEM, filter, kill/signal | libproc |
| `Battery` | %, charging state | IOPowerSources |

### Later / stretch

| Item | Note |
|---|---|
| Per-app network/disk breakdown | private NetworkStatistics — harder |
| **Per-process GPU/ANE attribution** | ⚠️ not reliably possible sudoless — deferred |
| History logging, configurable alerts | nice-to-have |

---

## 3. "AI Workload" view (roadmap — see NEXT_VERSION.md)

A dedicated, curated panel that answers "why is my AI workload slow?" at a glance:

```
┌─ AI Workload ──────────────────────────────┐
│ GPU    ███████████░  88%   24.3 W           │
│ ANE    ░░░░░░░░░░░░   2%  (est.)  idle       │
│ Mem BW ██████████░░  142 / 160 GB/s         │
│ Mem    wired 38.2 GB · pressure ●elevated   │
│ Power  package 41 W                          │
│ Thermal ● nominal (no throttle)             │
│ ─ Likely engine: GPU/Metal (LLM-style)  ─   │
└─────────────────────────────────────────────┘
```

- "Likely engine": GPU high / ANE low → `GPU/Metal (LLM-style)`; ANE high → `ANE (CoreML-style)`.
- Bandwidth near the chip ceiling → a `Bandwidth-bound` warning (LLM token-generation bottleneck).

This interpretation layer — not the raw numbers — is what sets WhisPlayInfo apart from
general-purpose monitors.
