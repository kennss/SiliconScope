# Roadmap — next version

v1.0.0 is a general Apple Silicon monitor. The next version specializes toward
**AI-inference monitoring** on Apple Silicon — the niche neither terminal monitors
nor Activity Monitor cover.

## Shipped (post-v1.0.2, on `main`)

- **AI Workload view (hero)** — a bottleneck classifier with a single verdict:
  *bandwidth-bound* / *compute-bound* / *thermal-throttled* / *memory-pressured*
  (plus *idle* / *GPU-active*). Front-and-center hero card on the dashboard, mirrored
  as a `Workload:` line in the menu bar. Precedence: memory > thermal > workload profile.
- **Per-chip memory-bandwidth ceiling table** + a **"% of ceiling" gauge**
  (M1–M4; Max bins disambiguated by P-core count; self-corrects up to the observed peak
  for chips outside the table).
- **GPU throttle detector** — flags the GPU clock held below its slowly-decaying rolling
  peak while thermal pressure has risen above nominal (banner + menu-bar flame).
- **Compact GPU menu-bar mode** — single line: `GPU% / GPU W / GPU GB/s / die °C`.

## Planned

- **AI runtime detection** — recognize `ollama`, `llama.cpp`, `MLX`, `LM Studio`, etc. and surface them
- **Engine attribution** — GPU/Metal vs ANE, as a clear hint
- **Model memory budget** — estimate the largest model that fits in free unified memory
- **WhisPlay process detect / pin**
- **Packaging** — `.app` bundle (icon, signing/notarization) + Homebrew cask

## Out of scope (sudoless limits)

- Per-process GPU / ANE attribution (not reliably available without elevated access)
- tokens/sec (needs runtime-log integration, not chip telemetry)

## Compatibility notes / lessons learned

### macOS 27 — launch crash via `Bundle.module` (fixed in v1.0.2)

- **Symptom:** v1.0.0/v1.0.1 crashed immediately on launch under macOS 27
  (`EXC_BREAKPOINT` / `_assertionFailure` in `static NSBundle.module`). Reported in
  issue #1 (Mac14,9, macOS 27.0 beta). Did not reproduce on macOS 26 and earlier.
- **Root cause:** SwiftPM's generated `Bundle.module` accessor calls `fatalError`
  when it cannot locate its resource bundle. We hand-assemble the `.app` (SPM emits
  no bundle), and the copied resource bundle `ktop_WhisPlayInfo.bundle` is a *flat*
  folder with no `Info.plist`. macOS 27 tightened bundle validation and no longer
  treats such a folder as a valid bundle, so every `Bundle.module` candidate path
  returned nil → `fatalError`. Older macOS accepted the flat folder, hiding the bug.
- **Fix (v1.0.2):** the app icon is now resolved via `Bundle.main` (packaged
  `Contents/Resources/AppIcon.icns`) with a manual SwiftPM-bundle fallback for dev
  runs — every `Bundle.module` reference was removed, so the `fatalError` path is
  gone regardless of bundle validity.
- **Forward action (for the Packaging item above):**
  - Never depend on `Bundle.module` in a hand-assembled `.app`; load resources from
    `Bundle.main` or by explicit path.
  - If a SwiftPM resource bundle must be shipped, give it a valid `Info.plist` so it
    is a real bundle on current macOS.
  - Smoke-test releases against the **latest macOS beta** before publishing — this
    class of bug only surfaces on the newest OS.
