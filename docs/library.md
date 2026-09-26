# Using SiliconScopeCore as a library

SiliconScope's measurement layer is a Swift package library, **`SiliconScopeCore`**. The app, the
`sscope-cli` diagnostic and the headless `sscope-agent-mac` are all thin programs on top of it. You
can link it into your own tool the same way — for example, to feed Apple Silicon metrics into your
own logging or dashboard pipeline.

> **Not a stable API.** SiliconScopeCore is the internals of an app, not a published SDK. Types,
> fields and signatures change whenever the app needs them to, in any release, without notice or a
> deprecation period. Pin an exact version and expect to adapt when you move it. Questions about
> using the library aren't supported in the issue tracker.

## Requirements

- **Apple Silicon Mac, macOS 14 or later.** Intel Macs are not supported by the Core.
- **Not for App Store or sandboxed apps.** The Core reads Apple's private IOReport interface and
  the SMC. That is what makes it work without `sudo`, and it is also why it can't pass App Review or
  run inside the App Sandbox.
- **Build with the Xcode toolchain** (`xcrun swift build`). A non-Xcode `swift` may not match the
  macOS SDK and fail with `Failed to build module 'Foundation'`.

## Adding the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kennss/SiliconScope", exact: "4.4.0"),
],
targets: [
    .executableTarget(
        name: "mytool",
        dependencies: [.product(name: "SiliconScopeCore", package: "SiliconScope")],
        linkerSettings: [
            // Required: IOReport has no SDK stub, so its symbols are resolved at runtime.
            .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
        ]
    ),
]
```

**The linker flag is required in your executable target.** Without it the link fails with
`Undefined symbols for architecture arm64: "_IOReportChannelGetChannelName" …`. The macOS SDK ships
no stub for IOReport, so the executable has to leave those symbols for dyld to resolve from the
system at launch. The library targets themselves carry no unsafe flags, which is why a
version-based dependency resolves normally.

Resolving the package also fetches Sparkle, which the app uses for updates. It is not linked into
your target.

## Minimal example

```swift
import Foundation
import SiliconScopeCore

let sampler = SystemSampler()          // keep ONE sampler alive for the life of your program
print(sampler.topology?.chipName ?? "unknown chip")

while true {
    let s = sampler.sample()           // blocks ~0.2 s: it measures across a short interval
    print("E \(s.cpu.eUsage)  P \(s.cpu.pUsage)  GPU \(s.gpu.usage)",
          "ANE \(s.ane?.activeFraction ?? .nan)  BW \(s.bandwidth.totalGBs) GB/s")
    if s.power.railsKnown { print("SoC \(s.power.socWatts) W") }
    Thread.sleep(forTimeInterval: 1)
}
```

`sample()` blocks for its measurement interval, so call it off the main thread in a GUI program.
`sample(demand:)` takes a `MetricGroup` set to measure only what you need; groups you leave out are
not read at all, which is cheaper.

## Three things that read as wrong numbers if you miss them

1. **The first sample's CPU usage is 0.** Per-core usage is the change in CPU ticks since the
   previous call, and the first call has nothing to compare against. Discard the first sample, or
   sample once at startup before you start recording.

2. **Power can be unknown, and unknown is not zero.** On macOS 27 the energy counters no longer
   update on every read. How often they do depends on the chip: every ~2 s on an M5 Max, but on an
   M1 Max only at power-management events (about every 30 minutes, and when the display turns on or
   off). The sampler works this out from what it observes, so it needs to keep running. Until it
   has a complete span, `power.railsKnown` is `false` and the wattage fields are placeholders that
   read `0`. Check it before using `cpuWatts`, `aneWatts`, `dramWatts` or `socWatts`:
   - `railsLive`: the value is current.
   - `railsAveraged`: the value is an average over `railWindowSeconds`.
   - `systemWatts`: the whole Mac's draw from the SMC, when the machine reports it. It stays live
     when the SoC rails are not.

3. **The ANE figure is activity, not watts.** `ane?.activeFraction` is the measured share of time the
   busiest Neural Engine cluster was active. It is `nil` on a Mac that doesn't expose the channel.
   `power.aneWatts` is the power estimate, and it is subject to point 2.

## If you want the Fleet JSON

`MachineMetrics` is the JSON shape the Fleet agents send. `MachineMetrics.mac(snapshot:…)` builds it
from a snapshot plus a few peaks that `MetricsEngine` tracks. Its parameters change as the Fleet
view grows, so copy the current call from the reference code below rather than from here.

## Reference code

- [`Sources/sscope-cli/main.swift`](../Sources/sscope-cli/main.swift) — reads every metric once and
  prints it. It is the quickest way to see what each field holds on your machine.
- [`Sources/sscope-agent-mac/main.swift`](../Sources/sscope-agent-mac/main.swift) — a long-running
  sample loop that builds `MachineMetrics` every second. It is the closest thing to a production
  consumer.
- [bitandmortar/SiliconScope `sscope-jsonl`](https://github.com/bitandmortar/SiliconScope) — a third-party tool in 78 lines. It prints one
  `MachineMetrics` JSON line per tick into a ClickHouse telemetry pipeline. It was written against an
  older release, so check it against the current signatures (see the stability note above).

## License

MIT, like the rest of the repository. The IOReport and SMC knowledge is adapted from NeoAsitop and
SocPowerBuddy, and the per-generation sensor tables from Stats. See the README's credits.
