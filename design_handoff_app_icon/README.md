# Handoff: WhisPlayInfo — macOS App Icon

## Overview
App icon for **WhisPlayInfo**, a macOS system monitor (the GUI counterpart to the terminal tool `ktop`). Its differentiator over `btop` and similar terminal monitors is that it tracks **Apple Neural Engine (ANE)** and **Media Engine** utilization in addition to CPU/GPU/memory/network.

The selected direction is **Option A — "Activity bars"**: a four-bar multicolor equalizer (red / amber / green / blue) on a dark squircle. It was chosen for best legibility at small sizes.

## About the Design Files
The files in this bundle are **design references**, not production source to ship verbatim:

- `WhisPlayInfo-icon-A.svg` — the **master vector**. This is the source of truth; scale/edit from here.
- `WhisPlayInfo-icon-A-1024.png` — 1024×1024 raster master (transparent corners outside the squircle).
- `icon-reference.html` — open in a browser to see the icon at 1024 + every downscaled size + in a Dock (light & dark).
- `generate_icns.sh` — builds a macOS `AppIcon.iconset` and compiles `AppIcon.icns`.

The task is to **integrate this icon into the app's build** using its native packaging (an Xcode asset catalog `Assets.xcassets/AppIcon.appiconset`, or a standalone `.icns` in the bundle's `Resources/`). Recreate from the **SVG master** so every size is crisp — do not upscale small rasters.

## Fidelity
**High-fidelity (hifi).** Final colors, geometry, and proportions. The SVG/PNG are production-ready masters; reproduce exactly. No restyling needed.

## The Icon — exact specification

All geometry is defined on a **1024 × 1024** canvas (the standard macOS icon master size).

### Shape — the squircle
- macOS-style **superellipse** (continuous-corner squircle), NOT a plain rounded rectangle.
- Curve: `|x/512|^5 + |y/512|^5 = 1` (superellipse exponent **n = 5**), centered at (512, 512), radius 512 — i.e. it fills the full 1024 canvas edge-to-edge. Corners outside the curve are transparent.
- The exact path is baked into `WhisPlayInfo-icon-A.svg` (`<clipPath id="clip">` and the background `<path>`). Reuse that path verbatim rather than regenerating.

### Background
- Vertical linear gradient, top → bottom: **`#27303C` → `#0C0F15`**.
- Plus a soft top radial glow: `radialGradient` centered at (50%, 14%), radius 70%, from `rgba(120,150,200,0.20)` → transparent. (Subtle cool sheen at the top.)
- Edge highlight: the squircle path stroked with a top-light gradient (`rgba(255,255,255,.5)` → `.05` → `0`), `stroke-width: 3`, `opacity: .9`. Gives a thin rim of light along the top edge.

### The four bars (the motif)
Pill-shaped vertical bars, all sharing: **width `108`**, **corner radius `54`** (fully rounded ends), bottoms anchored to **baseline y = 792**.

| Bar | x (left) | height | top y | Base color | Top-of-gradient (lighter) |
|-----|---------:|-------:|------:|------------|---------------------------|
| 1 (red)   | 188 | 470 | 322 | `#FF5A52` | `#FF8B85` |
| 2 (amber) | 368 | 560 | 232 | `#F2B33D` | `#FFD27A` |
| 3 (green) | 548 | 360 | 432 | `#5FD17A` | `#9BE8AD` |
| 4 (blue)  | 728 | 250 | 542 | `#5B9BF5` | `#9BC1FF` |

- Each bar is filled with a **vertical linear gradient** from its lighter top color (offset 0) to its base color (offset 1).
- **Gloss highlight** on each bar: a smaller pill at `x = barX + 14`, `y = topY + 18`, `width = 80` (108 − 28), `height = min(70, barHeight − 40)`, `rx = 40`, fill `rgba(255,255,255,0.28)`. Sits near the top of each bar.
- **Baseline rule**: a thin bar `x=150, y=788, width=724, height=6, rx=3`, fill `rgba(255,255,255,0.10)` — a faint ground line the bars rest on.

Bar order/colors map to the app's metric palette: **red = E-cores/CPU load, amber = ANE (the differentiator), green = GPU/P-cores, blue = network/IO.** Keep this order — amber being the tallest deliberately foregrounds the ANE story.

## Design Tokens

```
/* Surface */
--bg-top:        #27303C
--bg-bottom:     #0C0F15
--top-glow:      rgba(120,150,200,0.20)
--edge-light:    rgba(255,255,255,0.50)  /* fades to 0 down the icon */
--gloss:         rgba(255,255,255,0.28)
--baseline:      rgba(255,255,255,0.10)

/* Metric bar colors (base / light) */
--red:    #FF5A52 / #FF8B85   /* CPU / E-core      */
--amber:  #F2B33D / #FFD27A   /* ANE (Neural Engine) */
--green:  #5FD17A / #9BE8AD   /* GPU / P-core      */
--blue:   #5B9BF5 / #9BC1FF   /* Network / IO      */

/* Geometry (1024 canvas) */
squircle-exponent: 5
bar-width: 108   bar-radius: 54   baseline-y: 792
```

## Building the macOS icon

### Option 1 — quick `.icns` (provided script)
```bash
cd design_handoff_app_icon
chmod +x generate_icns.sh
./generate_icns.sh
```
Produces `build/AppIcon.icns`, the full `build/AppIcon.iconset/`, and a `build/png/` set (16…1024). The script renders from the SVG via `rsvg-convert`, `inkscape`, or `cairosvg` if available; otherwise it falls back to `sips` resizing the 1024 PNG.

### Option 2 — Xcode asset catalog
Add an **App Icon** set to `Assets.xcassets` and supply these PNGs (macOS slots):

| Slot | Size (px) |
|------|-----------|
| 16pt @1x / @2x | 16 / 32 |
| 32pt @1x / @2x | 32 / 64 |
| 128pt @1x / @2x | 128 / 256 |
| 256pt @1x / @2x | 256 / 512 |
| 512pt @1x / @2x | 512 / 1024 |

The `build/png/` output from the script (or re-rendering the SVG at each size) fills every slot. Then set the target's *App Icon* to this set.

### Notes
- The master art is **inset to Apple's icon grid**: a single transform group scales the squircle to **824×824** centered on the 1024 canvas (≈100px transparent margin each side), so the Dock icon matches stock macOS icons instead of sitting edge-to-edge. The earlier full-bleed art is in git history.
- Always regenerate small sizes from the **SVG**, never by upscaling 16/32px rasters.
- Corners must stay **transparent** (they already are in the master PNG/SVG).

## Files
- `WhisPlayInfo-icon-A.svg` — master vector (source of truth)
- `WhisPlayInfo-icon-A-1024.png` — 1024 raster master
- `icon-reference.html` — visual reference (sizes + Dock contexts)
- `generate_icns.sh` — iconset / `.icns` builder
- `README.md` — this document
