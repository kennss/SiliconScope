# Verified IOReport channel map (M1 Max, macOS 26.5)

> The real, measured locations of the channels WhisPlayInfo reads. These can differ per
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

| Channel pattern | Category |
|---|---|
| `ECPU DCS RD/WR`, `PCPU0/1 DCS RD/WR` | CPU |
| `GFX DCS RD/WR` | GPU |
| `PRORES / STRM CODEC DCS …` | Media Engine |
| `DISP / ISP / ANS / PCIE LN DCS …` | Other |

`GB/s = (bytes / interval_s) / 1e9`

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
