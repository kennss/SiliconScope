# Verified IOReport channel map (M1 Max, macOS 26.5)

> The real, measured locations of the channels SiliconScope reads. These can differ per
> chip — re-verify on other models. IOReport links via `-undefined dynamic_lookup`
> (symbols resolved at runtime from the dyld shared cache). Everything here is sudoless.

## Power — group `Energy Model`, format Simple, unit mJ

| Channel | Meaning | Notes |
|---|---|---|
| `CPU Energy` | total CPU power | = sum of EACC + PACC |
| `EACC_CPU` | E cluster | suffix `_CPU` = cluster total |
| `PACC0_CPU`, `PACC1_CPU` | P clusters 0 / 1 | M1 Max has two P clusters |
| `GPU0`, `GPU SRAM0` | GPU | `GPU Energy` uses a different unit (~nJ) → excluded |
| `ANE0` (`ANE1`) | Neural Engine | 0 when idle (expected) |
| `DRAM0` | memory | |

`Watts = (mJ delta / interval_s) / 1000`

## CPU frequency — group `CPU Stats`, subgroup `CPU Complex Performance States`, format State

| Channel | Cluster |
|---|---|
| `ECPU` | E |
| `PCPU`, `PCPU1` | P (two clusters) |

- state[0] = `IDLE`; active-state (`V0P4`…`V14P0`) residency × DVFS MHz, weighted = average frequency.
- The `*CPM` variants have IDLE=0 (fabric) → excluded.
- **CPU usage** is *not* taken from this residency (cluster residency over-counts). Usage
  comes from `host_processor_info` ticks (busy/total per core, averaged per cluster) to
  match Activity Monitor / iStat.

## DVFS frequency table — IORegistry `AppleARMIODevice`

| Key | Cluster | Measured (M1 Max) |
|---|---|---|
| `voltage-states1-sram` | E | 600…2064 MHz (5 steps) |
| `voltage-states5-sram` | P | 600…3228 MHz (15 steps) |
| `voltage-states9` | GPU | up to ~1296 MHz |

- Array of (freqHz, voltage) UInt32 pairs; `freqHz / 1e6 = MHz`; zero entries skipped.

## Memory bandwidth — group `AMC Stats`, subgroup `Perf Counters`, format Simple, unit bytes

**Verified on:** M1 Max, macOS 26.5 only. See the M4 Max / macOS 26.5.2 section below for a
chip/OS combination where this entire group fails to subscribe.

| Channel pattern | Category |
|---|---|
| `ECPU DCS RD/WR`, `PCPU0/1 DCS RD/WR` | CPU |
| `GFX DCS RD/WR` | GPU |
| `PRORES / STRM CODEC DCS …` | Media Engine |
| `DISP / ISP / ANS / PCIE LN DCS …` | Other |

`GB/s = (bytes / interval_s) / 1e9`

### macOS 27 beta / M3 Max — channel names restructured (unverified fix, documented upstream)

Not independently re-verified by this project — see
[github.com/kennss/SiliconScope#14](https://github.com/kennss/SiliconScope/issues/14) (filed by
the maintainer) for the full, hardware-verified writeup. Summary: on macOS 27.0.0 beta, an M3
Max still exposes the `AMC Stats`/`Perf Counters` group and its channels subscribe fine, but
Apple restructured the channel *names* three ways: a leading `DIE0` chip-id/per-core token
(`ECPU DCS RD` → `DIE0 ECPU0 DCS RD`), the combined `RD/WR` suffix split into separate channels
with several shapes (`RD/WR`, `RD/WR/RDWR`, `RD/WR + RD/WR`), and ~19 new unclassified requestor
families (`AVE0/1`, `SCODEC`, `SEP`, `SIO`, `ATC0-3`, `MSR0/1`, `PCIEGE`, `GFXA/B/C`,
`EXT_DISP0-3`). Separately, the surviving channels were observed reading the `INT64_MIN`
sentinel instead of real bytes — an open question, not solved by this project. `classify()` in
`BandwidthSampler.swift` now tolerates the `DIE0` prefix and the additional RD/WR suffix shapes
(see its `contains(_:unitPrefix:)` and `hasReadWriteToken`/`stripReadWriteSuffix` helpers), which
should address the naming/classification half of #14 — but this project has no macOS 27 hardware
to confirm the `INT64_MIN` half against.

### M4 Max / macOS 26.5.2 — "AMC Stats" subscription fails outright; data relocated to `PMP`/"DCS BW"

Verified on this project's own hardware (Apple M4 Max, macOS 26.5.2, Darwin). Distinct failure
mode from the macOS 27 case above: `IOReportCopyChannelsInGroup("AMC Stats", nil, 0, 0, 0)`
succeeds and enumerates ~190 channels, but `IOReportCreateSubscription` on that channel set
returns `nil` — the group is discoverable but not subscribable, regardless of subgroup filter
(tried both `nil` and `"Perf Counters"` explicitly). This is *not* a naming/classification
problem; no amount of `classify()` tolerance can fix it, since iteration never begins.

The equivalent per-requestor byte-traffic data is present elsewhere on this machine, under the
already-subscribable **`PMP`** group (539 channels total), in two subgroups — **`AF BW`**
(address-fabric-side, pre-cache) and **`DCS BW`** (DRAM-controller-side, the closer analog to
the old semantics) — encoded very differently: **State format**, not Simple. Each requestor
channel (e.g. `EACC0 RD+WR`, `PACC0 RD+WR`, `AGX RD+WR`, `JPEG0 RD+WR`) is a 32-state residency
histogram, with state names that are literally the bucket's GB/s value (`"   1GB/s"` …
`"  32GB/s"`) and each state's residency the time spent at approximately that bandwidth level
since the last sample — the same idiom `CPUSampler` already uses for DVFS-frequency residency
weighting, just applied to bandwidth instead of MHz.

Requestor spellings differ from the classic path too: `EACC0`/`PACC0`/`PACC1` (CPU clusters,
not `ECPU`/`PCPU`), `AGX` (GPU, not `GFX`), `ISP0`/`JPEG0`/`PRORES1`/`SCODEC0`/`AVE0`/`AVE1`/
`AVD0` (media). `BandwidthSampler` falls back to this path (`classifyPMPHistogramRequestor`,
`weightedAverageGBs`, `parseHistogramBucketGBs`) only when the classic `AMC Stats` subscription
fails, and only reads the combined `<requestor> RD+WR` channel per requestor (the separate
RD-only/WR-only breakdown channels are not also summed in, to avoid double-counting).

**Known limitation, observed and not solved here:** the top bucket (`"32GB/s"`) is very likely a
saturating/clamped bin rather than a literal ceiling — under a sustained heavy-GPU workload, the
`AGX RD+WR` channel showed a real residency spike concentrated in that top bucket (tens of ticks
out of a few hundred), and the always-on `AMCC` requestor (folded into `other`) was observed
reading *100% of its residency* in the top bucket continuously, even near-idle — suggesting
`AMCC`'s counter may not behave like the others. The weighted average is real, non-fabricated,
and moves correctly with load, but can understate true peak bandwidth for requestors that
saturate past 32 GB/s, and `other`/`total` may run persistently elevated because of `AMCC`. Not
fixed in this change; flagged for whoever picks up more precise interpretation of this histogram
next.

**Follow-up finding, confirming the above against this chip's real spec ceiling:** this M4 Max
(40-core GPU) has a theoretical unified-memory-bandwidth ceiling of 546 GB/s
(`Bottleneck.bandwidthCeilingGBs`). Under sustained, genuinely heavy GPU-bound inference (GPU
100%, 44–58 W GPU power, ~10–12 W DRAM power), the sampled `gpuGBs` topped out at **~28–31
GB/s — pinned right at the edge of the histogram's labeled 32 GB/s bucket** — while `totalGBs`
(the naive sum across ~20 requestor channels) climbed to 250–330 GB/s. A GPU that size should be
able to drive well past 32 GB/s on its own under real compute load, so a value sitting persistently
just under the top bucket's label is the clearest evidence the clamp theory above is correct for
`gpuGBs` specifically, not merely plausible. Also checked for a literal ceiling/absolute-bytes
channel elsewhere in `PMP` as a possible escape hatch: the `DCS Ceiling`/`DCS Floor`/`AFR Floor`/
`SOC Floor` subgroups exist, but they are DVFS **frequency/voltage**-state residency histograms
(state names like `F1`..`F6`, `VMIN`..`VOVD`) confirming the memory controller runs at its top
performance state under load — they do not expose a literal bytes/sec figure, so there is no
shortcut available to recover the true magnitude once a requestor's traffic exceeds its bucket's
labeled maximum.

Because of this, `BandwidthSample.isEstimated` is `true` for every reading from this fallback
path. The app surfaces that honestly rather than silently asserting precision it doesn't have:
the menu bar's `Workload` line and the dashboard AI Workload card's `Bandwidth-bound` state both
append `"(est.)"` when the bandwidth-bound verdict is based on an estimated reading — see
`MenuBarView.workloadLabel(_:)` and `DashboardView.AIWorkloadCard.memState`. Nothing in this
project currently renders a raw numeric "% of ceiling" gauge (that idea, mentioned in older
CHANGELOG entries, was superseded by this qualitative state card), so those two labels are the
full extent of the ceiling-relative UI surface affected.

Verify on your own machine: `xcrun swift run -q sscope-cli --bandwidth` (works whether your
machine uses the classic `AMC Stats` path or this `PMP`/`DCS BW` fallback — it dumps whichever is
actually subscribable), plus `sysctl hw.model machdep.cpu.brand_string` and the macOS build
(`sw_vers`).

## Non-IOReport sources

- **Topology:** sysctl `hw.perflevel0` (= Performance / P), `hw.perflevel1` (= Efficiency / E).
- **CPU usage:** `host_processor_info` (PROCESSOR_CPU_LOAD_INFO) ticks. E-cores are the
  first logical CPUs (indices `0..<eCoreCount`), P-cores the rest.
- **Memory:** `host_statistics64(HOST_VM_INFO64)` + sysctl `hw.memsize`, `vm.swapusage`;
  pressure level from sysctl `kern.memorystatus_vm_pressure_level` (1 normal / 2 elevated / 4 critical).
- **Fans:** SMC `FNum`, `F{i}Ac` (AppleSMC, `IOConnectCallStructMethod` kernel index 2, `flt` type).
- **Temperatures:** SMC `flt` keys by prefix — `Tp*` = CPU cores, `Tg*` = GPU, `Tm*` = Memory,
  `TB*` = Battery; `tcal` (calibration) excluded. Apple Silicon exposes ~3 sensors per CPU core,
  folded to one reading per core (hottest of the group).
- **Thermal pressure:** `ProcessInfo.thermalState`.
- **Network:** `getifaddrs` (AF_LINK `ifi_ibytes` / `ifi_obytes`).
- **Disk:** IOBlockStorageDriver `Statistics` (`Bytes (Read)` / `Bytes (Write)`) + volume capacity.
- **Battery:** `IOPSCopyPowerSourcesInfo`.
- **Processes:** `libproc` (`proc_listallpids`, `proc_pidinfo`, `proc_name`).
