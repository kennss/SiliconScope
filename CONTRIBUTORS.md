# Contributors

SiliconScope is maintained by one person on one Mac. A lot of what it gets right came from people
who measured on hardware it has never run on, fixed numbers that were wrong without looking wrong,
or wrote parts of it outright. This page is where they are credited.

## Measured on hardware this project doesn't have

**Most of the chips SiliconScope reads correctly are chips it has never run on.** That is not a
figure of speech: this project owns an M1 Max. M2 Max, M4 Max, M5 Max and Intel support exist
because people measured on their own hardware carefully enough that nothing had to be guessed.

- **[@fparrav](https://github.com/fparrav)** — M4 Max, **diagnosed and fixed**. He found that
  `AMC Stats` enumerates but refuses to subscribe — a different failure from the one already open —
  and then wrote the fix himself: the PMP histogram fallback that reads per-requestor bandwidth out
  of a residency histogram when the classic path is gone, plus a `--bandwidth` diagnostic, unit
  tests and the channel-map documentation
  ([#29](https://github.com/kennss/SiliconScope/pull/29), +626 lines). **That fallback is the
  foundation the M5 fix was later built on** — memory bandwidth and the Media Engine work on both
  generations because of his code.
- **[@ben0112](https://github.com/ben0112)** — M5 Max, measured to a standard this project could
  not have reached alone. The bandwidth path again (the group renamed `PMP` → `PMP0`), the AMCC
  bucket floor, and then the whole perf-level story: a chip with **no Efficiency cores**, the
  device-tree cluster map that now decides how *every* Mac splits its cores, and the rail→cluster
  mapping — each experiment repeated three times, with the watts cross-checked against the bare
  rail so double-counting could be ruled out rather than assumed
  ([#30](https://github.com/kennss/SiliconScope/issues/30)). His measurements are written up in
  [`docs/ioreport-channels.md`](docs/ioreport-channels.md).
- **[@kruzif-x](https://github.com/kruzif-x)** — M2 Max, **diagnosed** a fault that only shows up
  sometimes: the SMC's core temperature keys intermittently returning a constant 6.7 °C. Ten runs, a
  comparison against a second reader, and a two-minute watch turned "my CPU reads cold" into a rule
  every Mac now benefits from — a die is never colder than its room, so a die sensor reading single
  digits is dropped, and the HID sensors stand in. The same runs showed that `tcal` is a
  calibration point, not a reading ([#57](https://github.com/kennss/SiliconScope/issues/57)).
- **[@dewylouis](https://github.com/dewylouis)** — Intel MacBook Pro, the only Intel hardware the
  project has ever had readings from. His two fans and 47 sensors confirmed the Intel fan and `sp78`
  temperature path, and his suggestions for naming Intel's SMC keys were checked against VirtualSMC's
  key list and adopted where every model agrees ([#69](https://github.com/kennss/SiliconScope/issues/69)).

## Wrote parts of the app

- **[@durul](https://github.com/durul)** — **named this project.** It shipped as "WhisPlayInfo",
  a companion utility's name for something that had already outgrown it; he proposed
  **SiliconScope** in [#4](https://github.com/kennss/SiliconScope/issues/4), argued it from what the
  app actually is, and it has been the name ever since. He also wrote the AI-workload bottleneck
  classifier, the GPU throttle detector and compact GPU menu-bar mode
  ([#2](https://github.com/kennss/SiliconScope/pull/2)) — the bottleneck verdict on the dashboard is
  his — plus the local app-bundle build script ([#3](https://github.com/kennss/SiliconScope/pull/3)).
- **[@davidarny](https://github.com/davidarny)** — unified the popover action buttons into one
  style, made Settings focus when opened from a popover, inset the app icon to Apple's grid, and
  fixed Sparkle embedding in the dev build ([#7](https://github.com/kennss/SiliconScope/pull/7),
  [#8](https://github.com/kennss/SiliconScope/pull/8),
  [#9](https://github.com/kennss/SiliconScope/pull/9)).
- **[@Collinw24](https://github.com/Collinw24)** — oMLX inference-server support, and a
  `ProcessSampler` truncation fix found along the way
  ([#26](https://github.com/kennss/SiliconScope/pull/26)). Then memory bandwidth on an M3 Max under macOS 27, where the classic
  channels are gone and only one aggregate histogram is left: reported it, and fixed it narrowly
  enough that the M5 layout it must not touch stays as it was
  ([#46](https://github.com/kennss/SiliconScope/issues/46), [#47](https://github.com/kennss/SiliconScope/pull/47)).
- **[@zhangchen456](https://github.com/zhangchen456)** — the "Show Dock icon" setting, which is what
  lets SiliconScope run as a pure menu-bar utility.
- **[@mimen](https://github.com/mimen)** — the **Windows agent** ([#61](https://github.com/kennss/SiliconScope/pull/61)), Linux disk
  capacity with the container and NAS edge cases handled ([#62](https://github.com/kennss/SiliconScope/pull/62)), an Intel agent that
  reports the CPU it has instead of a fabricated GPU and Neural Engine ([#59](https://github.com/kennss/SiliconScope/pull/59)), and the
  M5 Max memory temperature key, verified on the die ([#58](https://github.com/kennss/SiliconScope/pull/58)).
- **[@TianjinAI](https://github.com/TianjinAI)** — oMLX shows the model that is loaded, not the
  first one installed ([#67](https://github.com/kennss/SiliconScope/pull/67)), and pointed out that LM Studio's path had the same flaw
  ([#66](https://github.com/kennss/SiliconScope/issues/66)).
- **[@ticlazau](https://github.com/ticlazau)** — the per-interface network breakdown: each
  interface's own throughput under the totals, names cached, VPN tunnels kept out of the totals so
  they no longer count the same bytes twice ([#74](https://github.com/kennss/SiliconScope/pull/74)). And M4 Pro GPU sensor readings,
  idle and under load, that showed the M4 table's GPU keys come in duplicate pairs
  ([#75](https://github.com/kennss/SiliconScope/pull/75)).
- **[@jrideout](https://github.com/jrideout)** — mlx-dspark detection, following its `--port` to the
  API it actually serves ([#48](https://github.com/kennss/SiliconScope/pull/48)).

## Found numbers that were wrong without looking wrong

- **[@YuriNachos](https://github.com/YuriNachos)** — five merged fixes in four days, every one of
  them in a value the dashboard was already displaying without complaint: `fpe2` SMC keys floored to
  whole units, IOReport's `INT64_MIN` "unpopulated" sentinel summed as if it were a real byte count,
  a used fraction that went negative on network volumes, and two path rules that read a *username*
  as an AI runtime ([#38](https://github.com/kennss/SiliconScope/pull/38),
  [#39](https://github.com/kennss/SiliconScope/pull/39),
  [#40](https://github.com/kennss/SiliconScope/pull/40),
  [#41](https://github.com/kennss/SiliconScope/pull/41),
  [#42](https://github.com/kennss/SiliconScope/pull/42)). Every one arrived with tests larger than
  the fix. These are the hardest bugs to notice from the inside — nothing looks broken.

## Reports that changed the app

A clear report of something wrong is how most of the fixes above began. These led directly to
changes:

- **[@Borda](https://github.com/Borda)** — power read 0 W after upgrading to macOS 27, which turned
  out to be Apple changing how the energy counters update, and the biggest fix of 4.4
  ([#65](https://github.com/kennss/SiliconScope/issues/65)).
- **[@shirok1](https://github.com/shirok1)** — the window couldn't close to the menu bar on macOS 27,
  which led to sampling only what is on screen ([#13](https://github.com/kennss/SiliconScope/issues/13)).
- **[@parkamonster](https://github.com/parkamonster)** — asked for more from the Intel agent, and
  caught a fabricated "Apple Silicon" label within the hour ([#56](https://github.com/kennss/SiliconScope/issues/56)).
- **[@havard-vold](https://github.com/havard-vold)** — LM Studio's loaded model was invisible
  ([#64](https://github.com/kennss/SiliconScope/issues/64)).
- **[@fatcutegg](https://github.com/fatcutegg)** — measured what Fleet cost on the wire: ~11 KB a
  poll every 3 s, ~9 GB a month per machine, and most of it a TLS handshake rather than data. That
  measurement found the cause, and Fleet now polls only while its window is open, over one kept
  connection, gzipped ([#71](https://github.com/kennss/SiliconScope/issues/71)).
- **[@progenitor-amborella](https://github.com/progenitor-amborella)** — worked out that Lockdown
  Mode and a block-all firewall hide a Mac from Fleet, and how to let it in ([#63](https://github.com/kennss/SiliconScope/issues/63)).

---

Bug reports that come with a measurement are worth more than most patches, and several of the
entries above started as exactly that.
