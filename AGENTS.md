# AGENTS.md

Instructions for AI coding agents working on SiliconScope. Humans: see
[CONTRIBUTING.md](CONTRIBUTING.md), which this file follows.

## Read first

SiliconScope is an **instrument**: it shows what it observes and says when it doesn't know.
Before writing code, read **"What SiliconScope shows — and what it won't"** in
[CONTRIBUTING.md](CONTRIBUTING.md). A change that breaks one of those rules will be declined however
well it is written — two well-tested PRs already were (#70, #73).

## Rules for any change

- **Name the source of every new value you display**: the IOReport channel, SMC key, sysctl,
  syscall or public API it is read from. If you can't name one, don't display the value.
- **When a value can't be obtained, show nothing or "—".** Don't estimate it, scale it from
  another metric, or fall back to 0.
- **Don't derive one quantity from another** (sensor count from core count, ANE use from GPU
  use, a label from a sort order). If the hardware doesn't report it, it isn't shown.
- **Don't read an app's own report of itself** — status files, beacons, logs it writes about
  itself. Runtimes are asked only through their documented public API, and only while their
  server process is observed running.
- **Never launch, wake, signal or restart a process, and never write or delete another program's
  files**, in order to observe it.
- **Sensor keys go into `SensorCatalog.swift` only with evidence**: `sscope-cli --sensors-all`
  output from the real Mac, idle and under load, in the PR. Unknown keys stay raw.
- **No network calls** beyond the update check and Fleet agents the user added. No telemetry.

## Rules for the code

- Build and test with the Xcode toolchain: `xcrun swift build`, `xcrun swift test` (a plain
  `swift` from swiftly fails with `Failed to build module 'Foundation'`). Agent changes:
  `cd agent && go test ./...` on Linux (the Go agent does not build for macOS).
- `SiliconScopeCore` must not `import SwiftUI`. Private-API declarations stay in `CIOReport`.
- Every source file starts with the project header (File / Created / Updated / Developer /
  Overview / Notes); bump `Updated:` on any file you change. Comments and UI text are English.
- Fleet wire fields (`MachineMetrics`) are optional and additive: absent means "unknown", `[]`
  means "none". New fields must decode on older viewers, and a viewer must accept agents that
  don't send them.
- Must compile under Swift 6.1 strict concurrency (`swift-tools-version: 6.1`), not only the
  newest compiler: no non-`Sendable` globals read off the main actor.
- Add a test for the logic you add, preferably a pure function separated from the
  hardware-coupled sampler.

## Rules for the pull request

- **One change per PR, from a branch made off the current `main`.** Not from your fork's `main`,
  and not stacked on another PR's commits.
- Open an issue first for anything beyond a fix: a new panel, data source, runtime, or wire field.
- In the description, state the exact Mac (model, chip, macOS) it was verified on, and say plainly
  what was checked on real hardware and what only against fixtures, mocks or reasoning.
- Don't claim more than the change does. If the description and the diff disagree, the PR
  will be asked to change.
