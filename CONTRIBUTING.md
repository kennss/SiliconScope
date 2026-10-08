# Contributing to SiliconScope

Thanks for helping! The single most useful contribution right now is **verifying or fixing
the per-chip temperature sensor keys** — read on.

## Quick start

Requires macOS 14+ on Apple Silicon and the Xcode toolchain. **Always use `xcrun`** (a plain
`swift` from swiftly won't match the SDK and fails with `Failed to build module 'Foundation'`):

```bash
xcrun swift build                 # build everything
xcrun swift run SiliconScope      # the GUI (dashboard + menu bar)
xcrun swift run -q sscope-cli     # data-layer probe (no sudo)
xcrun swift test                  # unit tests (pure value/math logic)
```

No `sudo` is ever required, and **nothing leaves your Mac** — no outbound network calls, no
telemetry. Keep it that way (PRs that phone home, even for "anonymous stats", won't be merged).

## What SiliconScope shows — and what it won't

SiliconScope is an instrument. It shows what it observes, and when it can't know something it says
so rather than filling the gap. Every rule below came out of a real change, accepted or declined.

1. **Only measured values.** A value on screen comes from something read on this machine
   (IOReport, the SMC, HID sensors, sysctl, the process table) or from an agent that read it on its
   own. A missing value is shown as missing ("—"), never as 0 and never estimated from something
   else. On macOS 27, when the energy counters stop moving, the watts say "—" until there is a span
   to average, rather than reading 0 W.
2. **A runtime's word only through its own public API.** Ollama's or LM Studio's endpoints are
   interfaces the runtime promises to all its users, with open code and many tools depending on
   them; that is why their answers are trusted. They are asked only while that server is seen
   running, on the port it was seen serving (#53).
3. **An app's self-report is not a measurement.** A status file, beacon or log line an app writes
   about itself can't be checked, and can outlive the truth. SiliconScope doesn't display them, for
   other people's apps or its own: Spectalo and SpectaLing are recognised by their bundle path and
   shown as "on-device app — runs Core ML in-process", without a model or a progress bar (#70).
4. **Observing never changes what is observed.** No launching, waking or restarting a process to
   read it. Starting `lms log stream` to read LM Studio's speed launched LM Studio itself; it now
   attaches only to an LM Studio already running (#60). The same goes for files: SiliconScope
   doesn't write or delete other programs' data.
5. **It describes; it doesn't advise.** No warnings that tell you what to do, no "health scores",
   no automatic actions. High load on a busy machine is a healthy reading, not a problem (#22).
6. **A name it can't vouch for stays raw.** A sensor or key is named only when its meaning is
   known. SMC temperature keys are not GPU cores — an M1 Max has 32 GPU cores and 4 GPU sensors — so
   a count or a label is never derived from something else (#73). Intel keys are named only where
   every description in VirtualSMC's key list agrees (#69).
7. **Only verified keys go into the sensor tables**, with evidence: `sscope-cli --sensors-all`
   output from the actual Mac, idle and under load (see below). A reading that fails its check —
   a die below room temperature — is dropped from the panel and shown as rejected in the
   diagnostic, not passed off as a temperature (#57).
8. **Nothing leaves your Mac that you didn't ask for.** No telemetry, no analytics. The only
   outbound requests are the update check and the Fleet agents you add yourself, and Fleet polls
   only while fleet data is on screen (#71).
9. **Say what was tested.** A PR states the exact Mac it was verified on, and says plainly when
   something was checked against a simulation, a fixture or reasoning instead of real hardware.

If a change you have in mind runs against one of these, open an issue first — there may be a way
to get the same answer from something that can be measured.

## ⭐ Contributing temperature sensor keys (most wanted)

SiliconScope shows real **per-unit** temperatures (E-Core / P-Core / GPU / Memory) by reading
**curated SMC FourCC keys per chip generation**. The keys are near-arbitrary and change every
generation, so they're hand-maintained in
[`Sources/SiliconScopeCore/SensorCatalog.swift`](Sources/SiliconScopeCore/SensorCatalog.swift).

**Status:** the **M1** table is validated on real hardware (M1 Max). **M2–M5 are adapted from
[Stats](https://github.com/exelban/stats) but NOT yet verified** on-device. If you have an
M2/M3/M4/M5 (especially Pro / Max / Ultra / base variants), please confirm or correct them.

### How to verify your chip (one command)

```bash
xcrun swift run -q sscope-cli --sensors
sysctl hw.model machdep.cpu.brand_string
```

`--sensors` prints, for your detected generation, every curated key with the value it reads
back (or `— (not present)`), then the raw HID sensor list. Example on an M1 Max:

```
=== curated SMC keys — generation: m1 ===
  Tp01  P-Core 1   57.2 C
  Tg05  GPU 1      57.1 C
  ...
  → 18/18 curated keys read back
```

**What to check:**
- Do the **counts** match your chip? (e.g. an 8-GPU-core M3 Pro shouldn't have GPU 1–10.)
- Do values look **plausible** (~30–100 °C under light load), and rise on the right unit when
  you load it? (`yes > /dev/null &` heats CPU; a GPU/LLM load heats GPU.)
- Any key reading `— (not present)` that *should* exist → it's wrong/missing for your model.

### How to fix the table

Open an issue (or PR) titled e.g. **"Sensor keys: M3 Pro"** and paste:
1. the full `--sensors` output, and
2. the `sysctl` line (your exact model + brand string).

To edit it yourself, find your generation in `SensorCatalog.swift` and adjust the
`cpu(...) / gpu(...) / mem(...)` key→name pairs, then:

```bash
xcrun swift test --filter SensorClassificationTests   # catalog-shape tests must still pass
xcrun swift run -q sscope-cli --sensors               # confirm your keys read back
```

Variants need no special-casing — keys absent on a given die simply don't read back and are
skipped, so it's safe to list every key a generation can have.

## Coding conventions

- **English only** in code and all app-facing text (labels, menus, tooltips, units). Design
  docs may be other languages; shipped strings may not.
- **File header** on every source file (name / created / updated / developer / overview / notes).
  Bump `Updated:` when you change a file.
- **Layer separation:** `SiliconScopeCore` must not `import SwiftUI` — it's the UI-independent
  data layer shared by the app, the CLI, and tests. Keep private-API calls isolated in
  `CIOReport` behind safe Swift wrappers.
- **Adapted code** (e.g. NeoAsitop, Stats — both MIT) must be credited in the file's Notes.
- Prefer adding a **pure function + a test** over logic buried in a hardware-coupled sampler
  (see `Bottleneck`, `BandwidthSampler.classify`, `BatterySampler.healthPercent` for the pattern).

## Pull requests

- **One change per PR, on a branch made from the current `main`.** Don't open a PR from your
  fork's `main`, and don't stack one PR's commits under another — each must merge on its own.
- Make sure `xcrun swift build` and `xcrun swift test` both pass (and `go test` in `agent/` for
  agent changes).
- Describe what you changed and on which exact Mac model you verified it.
- For anything larger than a fix — a new panel, a new data source, a new field on the Fleet
  wire — open an issue first.

This is a private-API app, so it can't ship on the App Store — see the README for why.
