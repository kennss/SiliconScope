# AI runtime beacons

SiliconScope finds local AI runtimes from the process table: a bundle path
(`/Ollama.app/`), a basename (`llama-server`), or argv (`python -m vllm`). That covers
servers and CLIs. It does not cover an inference framework that is **statically linked
into a host app**. A SwiftPM MLX package inside `MyApp.app` leaves nothing in the path,
the basename, or argv that says "a diffusion model is running here". The process table
shows `MyApp` using 30 GB and a busy GPU, and nothing else.

A beacon lets the runtime report itself. While a heavy operation runs (generation,
training, model load), the framework keeps a small JSON manifest in a shared directory.
When the operation ends, it deletes the file. SiliconScope reads the directory on every
runtime scan and:

- **identifies** a process that no path, basename, or argv rule matched. It appears in
  the AI Workload card under the manifest's `displayName`;
- **adds activity** to a process that was already matched: task, model, phase, and a
  step/total progress. Path identity keeps naming the process. A beacon never
  reclassifies it.

The convention does not belong to any one producer. Any local inference framework in any
language can adopt it, and SiliconScope does not have to know the producer in advance.

## The contract (schema version 1)

### Location and file name

```
~/Library/Application Support/ai-runtime-beacons/<pid>-<id>.json
```

- `<pid>`: the producer's own process id, in decimal. It is the part before the first
  `-`, and the consumer reads the pid from the **file name**. It must equal the `pid`
  field in the JSON, or the file is ignored. This keeps one process from speaking for
  another.
- `<id>`: any token without a `-` that is unique within the process. Eight hex
  characters of a UUID work. Use one file per operation. Nested or concurrent operations
  in the same process are allowed, and the consumer shows the one with the latest
  `updatedAt`.
- The extension must be `.json`. Other files are ignored.
- The producer creates the directory if it is missing (`mkdir -p`).

### Manifest

```json
{
  "version": 1,
  "pid": 1234,
  "runtime": "ltx-video-swift-mlx",
  "displayName": "LTX-Video",
  "task": "generate",
  "model": "distilled",
  "phase": "denoising",
  "step": 3,
  "totalSteps": 11,
  "startedAt": "2026-07-15T09:00:00Z",
  "updatedAt": "2026-07-15T09:00:42Z"
}
```

| Field         | Type            | Required | Meaning                                                                 |
|---------------|-----------------|----------|-------------------------------------------------------------------------|
| `version`     | int             | yes      | Always `1` for this schema.                                             |
| `pid`         | int             | yes      | Producer's pid. Must match the file name.                               |
| `runtime`     | string          | yes      | Stable, machine-readable id. The package or repo name works: `flux-2-swift-mlx`. |
| `displayName` | string          | no       | Name shown to the user: `FLUX.2`. Without it, the UI shows "AI runtime".  |
| `task`        | string          | no       | Operation kind: `generate`, `train`, `load-models`, `transcribe`, …     |
| `model`       | string          | no       | Model or variant in use: `klein-9b`, `distilled`.                       |
| `phase`       | string          | no       | Current stage: `text-encoding`, `denoising`, `decoding`, …              |
| `step`        | int             | no       | Current step. With `totalSteps`, it drives the progress bar.            |
| `totalSteps`  | int             | no       | Total steps. Progress is `step / totalSteps`, clamped to 0…1.           |
| `startedAt`   | ISO-8601 string | no       | When the operation began.                                               |
| `updatedAt`   | ISO-8601 string | no       | Last refresh. It decides which manifest wins when one pid has several.   |

Dates are **ISO-8601 in UTC without fractional seconds** (`2026-07-15T09:00:42Z`). This
is Foundation's `JSONEncoder.dateEncodingStrategy = .iso8601`. A date with fractional
seconds fails to decode, and the whole manifest is skipped. Unknown extra keys are
ignored, so producers can add fields without breaking the consumer.

### Lifecycle rules

1. **Opt-in, off by default.** Nothing is written unless the host enables it, with a
   code flag, an environment variable (`<NAME>_RUNTIME_BEACON=1`), or a CLI `--beacon`
   flag. A library must never touch the user's Application Support folder on its own.
2. **One manifest per heavy operation.** Write it when the operation starts. Delete it
   when the operation ends, on every path, errors included (`defer`, `finally`, or a
   context manager).
3. **Atomic writes.** Write to a temp file and rename it (`Data.write(options: .atomic)`
   or `os.replace`), so a monitor never reads half a file.
4. **Throttle updates.** Refresh on phase or step changes, at most about once per
   second. SiliconScope samples every few seconds, so anything faster is wasted I/O.
5. **Never fail the real work.** Swallow every beacon I/O error. A beacon that cannot be
   written disables itself quietly.
6. **Crash safety is shared.** A `kill -9` can leave a manifest behind. Consumers delete
   any manifest whose pid is dead (`kill(pid, 0)` returning `ESRCH`) when they see it.
   Producers should do the same for *other* dead pids when they start a session. They
   must never delete files that belong to their own pid.
7. **No sandbox.** A sandboxed app's Application Support is inside its container, where
   no monitor can see it. The beacon is meant for CLIs and non-sandboxed apps.

## What SiliconScope does with it

- `RuntimeBeaconReader` (`Sources/SiliconScopeCore/RuntimeBeaconReader.swift`) reads the
  directory on every scan and does not cache the result, because beacons appear and
  disappear during a process's life. It removes dead-pid files, skips undecodable ones,
  and keeps the freshest manifest per pid.
- `AIRuntimeSampler` merges the manifests with the path/argv verdicts:
  - matched process with a beacon: same kind and name, plus `AIRuntimeProcess.beacon`;
  - unmatched process with a beacon: `AIRuntimeKind.fromBeaconRuntime(runtime)`. Known
    ids map to a dedicated case (`ltx-video-swift-mlx` → `.ltxVideo`). Unknown ids map to
    the generic `.beacon` kind, named after the manifest's `displayName`.
- The **AI Workload card** shows one activity row per process with a beacon (task · model ·
  phase · progress). `sscope-cli` prints the same data on a `beacon:` line.
- Beacon-only runtimes report `servesAPI == false`, so SiliconScope does not try to
  reach an HTTP API for them.

Check a producer from the terminal while it runs:

```sh
ls ~/Library/Application\ Support/ai-runtime-beacons/
swift run sscope-cli | sed -n '/AI runtime/,/primary/p'
#   FLUX.2  pid 81234  96% CPU  24.3 GB
#     beacon: flux-2-swift-mlx · generate · klein-9b · denoising · 50%
```

## Reference producers

- `ltx-video-swift-mlx`: `Sources/LTXVideo/Utils/RuntimeBeacon.swift` (`LTX_RUNTIME_BEACON=1`,
  `ltx-video --beacon`)
- `flux-2-swift-mlx`: `Sources/Flux2Core/Utils/RuntimeBeacon.swift` (`FLUX2_RUNTIME_BEACON=1`,
  `--beacon` through `BeaconOptions`)

Both use the same Swift file with a different `runtimeID` and `displayName`. The pattern
at a call site:

```swift
let beacon = RuntimeBeacon.begin(task: "generate", model: model.rawValue)
defer { beacon?.end() }
for step in 0..<steps {
    beacon?.update(phase: "denoising", step: step + 1, totalSteps: steps)
    // …
}
```

A minimal producer in Python (PyTorch/MLX scripts and similar):

```python
import json, os, time, uuid, contextlib
from datetime import datetime, timezone

BEACON_DIR = os.path.expanduser("~/Library/Application Support/ai-runtime-beacons")

def _now():
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")

@contextlib.contextmanager
def runtime_beacon(runtime, display_name, task, model=None, enabled=None):
    if enabled is None:
        enabled = os.environ.get("MYRUNTIME_RUNTIME_BEACON") == "1"
    if not enabled:
        yield lambda **_: None
        return
    pid = os.getpid()
    path = os.path.join(BEACON_DIR, f"{pid}-{uuid.uuid4().hex[:8]}.json")
    m = {"version": 1, "pid": pid, "runtime": runtime, "displayName": display_name,
         "task": task, "model": model, "startedAt": _now(), "updatedAt": _now()}
    last = 0.0
    def write():
        try:
            os.makedirs(BEACON_DIR, exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({k: v for k, v in m.items() if v is not None}, f)
            os.replace(tmp, path)
        except OSError:
            pass
    def update(phase=None, step=None, total_steps=None, force=False):
        nonlocal last
        m.update(phase=phase, step=step, totalSteps=total_steps, updatedAt=_now())
        if force or time.monotonic() - last >= 1.0:
            last = time.monotonic()
            write()
    write()
    try:
        yield update
    finally:
        with contextlib.suppress(OSError):
            os.remove(path)
```

The temp file ends in `.json.tmp`, not `.json`, so readers never pick it up.

## Prompt for a coding agent

Paste the block below into Claude Code (or any coding agent) in the repository of the
inference framework that should report itself. Replace the three placeholders first.

````text
Add an opt-in "AI runtime beacon" to this project so that external monitors (SiliconScope)
can see when it runs a heavy operation, and what it is doing.

Identity to use:
- runtime id:     <RUNTIME_ID>        (stable, e.g. the package name: "flux-2-swift-mlx")
- display name:   <DISPLAY_NAME>      (e.g. "FLUX.2")
- env variable:   <PREFIX>_RUNTIME_BEACON   (beacon enabled when it equals "1")

Contract (schema version 1). Follow it exactly, the consumer is strict:
1. Directory: ~/Library/Application Support/ai-runtime-beacons/ (create it if missing).
2. One file per heavy operation, named "<pid>-<id>.json". <pid> is this process's pid in
   decimal, and <id> is a unique token WITHOUT any "-" (e.g. 8 hex chars of a UUID).
3. JSON body:
   { "version": 1, "pid": <int, same as file name>, "runtime": "<RUNTIME_ID>",
     "displayName": "<DISPLAY_NAME>", "task": "<generate|train|load-models|…>",
     "model": "<variant or null>", "phase": "<current stage>", "step": <int>,
     "totalSteps": <int>, "startedAt": "<ISO-8601>", "updatedAt": "<ISO-8601>" }
   Only version, pid, and runtime are required. Omit unknown optional fields.
   Dates are ISO-8601 UTC WITHOUT fractional seconds ("2026-07-15T09:00:42Z").
4. Disabled by default. Write nothing unless the host enables it: a public static toggle
   (e.g. `RuntimeBeacon.isEnabled = true`), OR env <PREFIX>_RUNTIME_BEACON=1 read live
   (getenv / os.environ at call time), OR a `--beacon` flag on the CLI that sets the toggle.
5. Write the manifest when the operation starts. Refresh it on phase/step changes, at most
   about once per second. Delete it when the operation ends, on EVERY path, errors and
   cancellation included (defer / finally / context manager / deinit safety net).
6. Atomic writes only (write to a temp file whose name does not end in ".json", then rename;
   in Swift `Data.write(to:options: .atomic)`).
7. Beacon I/O must never throw into, block, or slow the real work. Swallow all errors.
8. When a session starts, delete manifests in the directory whose pid is dead
   (kill(pid, 0) == -1 && errno == ESRCH) and is not our own pid.
9. Thread safety: an update racing with end() must never recreate a deleted file. Keep the
   ended-flag check and the file write under the same lock.

Where to hook it:
- Find every heavy entry point (generation/inference loop, training loop, model loading)
  and wrap each one in a beacon session: task = the operation kind, model = the variant in use.
- Inside step loops, report phase + step/totalSteps (e.g. phase "denoising", step i+1).
  Use distinct phase names for distinct stages (text-encoding, denoising, decoding, saving…).
- If the project ships a CLI, add a `--beacon` flag on the heavy commands that turns it on.

Deliverables:
- The beacon module (Swift: an enum `RuntimeBeacon` with `begin(task:model:) -> Session?`
  and `Session.update(phase:step:totalSteps:)` / `end()`. Other languages: the equivalent
  context manager or RAII guard).
- Call sites wired in as described above.
- Tests, with the beacon directory overridable through a test hook so tests never write to
  the real one:
  (a) disabled by default, so no file is written;
  (b) enabled, so the file exists during the operation with the right name, pid, runtime,
      and ISO-8601 dates, and is gone afterwards;
  (c) the file is removed when the operation throws;
  (d) update() after end() does not recreate the file;
  (e) a manifest for a dead pid is cleaned up when a new session starts.
- A short README section: what the beacon is, how to enable it (toggle / env / --beacon),
  and a sample manifest.

Reference implementation with the same contract, to mirror in Swift projects:
ltx-video-swift-mlx, Sources/LTXVideo/Utils/RuntimeBeacon.swift.

To check the result by hand, run a real operation with the beacon enabled and watch
`ls ~/Library/Application\ Support/ai-runtime-beacons/`. The file must appear, change as steps
advance, and disappear at the end. If SiliconScope is running, its AI Workload card shows
<DISPLAY_NAME> with the live phase and progress.
````
