# Elyxr — visual design

The appearance and interaction specification. System behaviour — network, sync,
updates — is in [SPECS.md](SPECS.md).

Exact colours and sizes are defined in code, not duplicated here:

- `elyxr/lib/design/oklch.dart` — the colour engine.
- `elyxr/lib/design/tokens.dart` — accents, palette, densities, faces.
- `elyxr/lib/design/text.dart` — the three type roles and their scales.

This document defines the design rules, the invariants they must hold to, and
the interaction model.

---

## The idea

Elyxr presents as a piece of hardware: a tinted metal chassis with a phosphor CRT
tube recessed into it.

Everything behind the glass is terminal. Everything on the metal is a physical
control. This division governs placement and typography throughout.

The window is a fixed 440 × 884, portrait, not resizable.

---

## Layout

```
┌─ chassis ──────────────────────┐
│  top rail                      │   screw · ELYXR · hold-bar · vent · v2.0.5 · screw
│  ┌─ tube ────────────────────┐ │
│  │  console block            │ │   ticker, then host/link/free + capacity
│  │  find row                 │ │   FIND, text field, sort (NAME/SIZE/DATE)
│  │  breadcrumbs              │ │   /ELYXR / MUSIC / ALBUMS      ▲ UP
│  │  file list  or  grid      │ │   fills remaining space
│  │  selection + transfers    │ │   selection bar and queue appear when active
│  └───────────────────────────┘ │
│  bottom rail                   │   TEXT/GRID rocker · status LED
└────────────────────────────────┘
```

The chassis is a near-vertical metal gradient with a machined bevel: a bright
highlight hairline along the top edge and a recessed dark hairline along the
bottom. The tube is recessed behind a bezel ring and a soft inner vignette.

Both rails are drag handles for moving the window. The tube is not — it scrolls
and receives clicks.

---

## Color

Colour is a system, not a table. Every colour on screen — the glowing tube, the
paper terminal in light mode, and the metal — is derived from a single hue by a
perceptual (OKLCH) engine. A whole screen resolves to one phosphor colour and
holds it. Adding an accent is one row of four numbers in `tokens.dart`.

### Invariants

- A screen renders in a single colour. Two competing colours indicate a defect.
- The accent hue drives the phosphor and the metal alike. The metal carries only
  a whisper of the hue — a tinted grey, never a coloured chassis.
- Hue is preserved under saturation. Requesting more chroma than sRGB can show
  clamps the chroma; it never lets the hue drift.

### OKLCH

A colour is specified as **L** (perceptual lightness 0–1), **C** (chroma), and
**h** (hue angle in degrees). OKLCH is perceptually uniform: equal numeric moves
read as equal visual moves across hues.

A hue can only reach a certain chroma at a given lightness before leaving the sRGB
gamut. Rendering an out-of-gamut value lets the display gamut-map it, which shifts
the hue (deep blue toward teal, deep orange toward red). The engine therefore
takes a hue plus a chroma *budget* and returns the richest colour that remains
true to the hue.

### Engine

`oklch.dart` is pure Dart (ARGB ints, no Flutter) and is unit-tested against an
oracle.

- **OKLab → linear sRGB.** L,C,h convert to OKLab (`a = C·cos h`, `b = C·sin h`),
  then through the standard OKLab matrix to linear-light R,G,B. Coefficients in
  `_linear`.
- **Gamut test.** A colour fits sRGB when every linear channel is within `[0,1]`
  (0.001 slack).
- **`maxChroma(l, h)`** — the maximum in-gamut chroma for a lightness and hue, by
  a 20-step binary search over `C ∈ [0, 0.4]`. The primitive the rest builds on.
- **Encode.** Linear channel → 8-bit sRGB via gamma companding (`12.92·x` below
  `0.0031308`, else `1.055·x^(1/2.4) − 0.055`), clamped 0–255.
- **`oklchArgb(l, c, h)`** renders chroma as given; used only where chroma is
  already gamut-safe (the achromatic mono/white).
- **`trueArgb(l, h, reqC)`** = `oklchArgb(l, min(reqC, maxChroma(l, h)), h)` — the
  gamut clamp. The default for hue-bearing colour.
- **`accentChroma(chromaMul, maxCeil, sat)`** — the accent swatch's chroma:

  ```
  c = 0.13 · chromaMul · sat
  c = max(c, 0.045)     # floor — retains a trace of colour
  c = min(c, maxCeil)   # ceiling — the hue's chroma budget
  ```

- **`lForC(h, targetC, hiL, loL)`** — the lightest (or darkest) lightness that can
  hold a target chroma for a hue. Available for equalising chroma across hues; the
  current palette pins lightness per role and does not use it.

### Accents

Eight, in spectrum order. Each is `AccentSpec(hue, chromaMul, maxCeil, baseL)`.
`mono` is the achromatic white phosphor; its intensity is a lightness. Green is
the default.

| Accent | hue° | chromaMul | maxCeil | baseL |
|---|---|---|---|---|
| red | 18 | 1.00 | 0.223 | 0.56 |
| amber | 82 | 1.00 | 0.207 | 0.70 |
| green | 145 | 1.00 | 0.244 | 0.56 |
| cyan | 195 | 0.95 | 0.168 | 0.62 |
| blue | 255 | 1.00 | 0.212 | 0.56 |
| purple | 307 | 1.10 | 0.258 | 0.58 |
| pink | 352 | 0.95 | 0.190 | 0.70 |
| mono | — | 0 | — | 0.72 |

`tokens.dart` is canonical for these values.

### Palette recipe

From a hue `h` and the accent's `maxCeil`, each role is a fixed lightness at a
chroma that is a fraction of the budget, rendered through `trueArgb`. `wc`/`mc`
are 1 for a colour accent, 0 for mono.

- **Accent swatch** `a` = `trueArgb(baseL, h, accentChroma(...))` (mono:
  `oklchArgb(monoL, 0, 0)`).
- **Ink** on the accent: dark (`L 0.24`) when the accent is light (`>0.70`), else
  white.
- **Metal** — hue at a whisper of chroma (`0.008–0.016`), identical in both modes:
  `m1 L.240 · m2 .160 · m3 .130` (gradient), `mb .300` (border), `mh .400`
  (highlight), `mt .550` / `ml .860` (text), `mv1 .100` / `mv2 .210` (recess,
  vent).
- **Phosphor, dark** (glowing tube): `bright L.88 @ 0.9·budget · soft .34@.55 ·
  mid .66@1.0 · dim .44@.85 · foot .52@.70 · glow .60@1.0 · tube-bg L.085`.
  `bright`'s chroma scales with the saturation drag (capped ×1.5).
- **Phosphor, light** (paper terminal): `bright L.28 · soft .42@.80 · mid .50@.80
  · dim .80@.40 · foot .62@.60 · glow .55@1.0 · tube-bg L.940`.

### Saturation drag

The accent swatch responds to a vertical drag, live across the app.

- A colour accent drags saturation and glow together — `sat` feeds both
  `accentChroma` and the bright-glow scale. Range `0.25 – 3.2`: near-grey at the
  bottom, the hue's in-gamut peak at the top.
- `mono` drags lightness (`monoL`, `0.12 – 0.99`), graphite to white.

Selecting a different accent resets its intensity to neutral.

### Tube overlays

Three separate elements render over the glass and remain distinct:

- **Scanlines** — phosphor-tinted hairlines every 4px. Static texture; it does not
  move. Rasterised to a cached layer so scaling the fixed chassis resamples one
  texture rather than redrawing hairlines each frame.
- **Sweep** — a single thin scanner line crossing top to bottom, one pass every
  ~11 seconds, near-translucent with a faint glow. A moving line, not a lit band
  drawn across the texture.
- **Vignette + bloom** — a soft accent bloom at the centre easing to a gentle dark
  ring at the edges. A falloff, not a black frame; corners remain legible.

---

## Type

Three roles, one face each. The terminal face is user-selectable.

| Role | Applies to | Face |
|---|---|---|
| `chassis()` | Chassis labels, section markers, rail buttons | **Chakra Petch**, fixed |
| `glass()` | Everything on the glass — rows, readouts, settings | the terminal face |
| `mono()` | The ticker and glass readouts | the terminal face |

- The terminal face is selectable in Settings › TYPEFACE, from VT323 (default)
  through the bundled faces. It governs `glass()` and `mono()` together: the whole
  screen renders in one face. A face is added by placing a TTF in `assets/fonts/`,
  declaring it in `pubspec.yaml`, and adding a row to `kTermFaces`.
- The metal face (`chassis()`) is fixed. The `v2.0.5` badge on the rail is metal
  and uses the chassis face, so it is unaffected by the terminal-face selection.
- The ticker uses the terminal face, as part of the screen. A monospace terminal
  face yields a monospace ticker.

`text.dart` provides one scale knob per role.

---

## Interactions

### Wordmark hold — Settings

Holding the wordmark for ~250ms opens Settings; holding again returns to files.
Releasing before the threshold does nothing. During the hold the wordmark tightens
its tracking, lights to the accent with a glow, and a bar beside it fills. The
wordmark stays lit while Settings is open.

There is no settings button, tooltip, or hint. This entry point is intentionally
unmarked.

### Tactile feedback

Clickable surfaces light the same accent glow across devices: a mouse hover and a
touch press resolve to one lit state, through the `Tactile` wrapper. It is passive
and does not consume the underlying gesture.

### Accent swatches

Each swatch is a miniature tube in that colour, previewing the rendered surface
rather than a flat sample. Tap to select; drag vertically to set intensity
(saturation and glow for a colour, lightness for mono); double-tap to reset.

### Typeface picker

A grid of faces, each chip rendered in its own font. Tap to apply the terminal
face live.

### Density

TIGHT / MID / ROOMY sets a global text scale for the glass (≈0.9 / 1.0 / 1.15).
The whole terminal scales together; the metal rails keep their fixed size. Row
padding also tracks density.

### TEXT / GRID

A rocker on the bottom rail. TEXT is the dense phosphor list (default); GRID is
3-across tiles. Hidden while Settings is open, as it controls only the file list.
Persists.

### File rows

- Single click selects (files and folders alike).
- Double-click opens a folder or previews a file.
- Dragging a file sideways out of the window downloads it to the drop location; a
  vertical drag scrolls.
- Long-press renames.

### Ticker

Scrolls right-to-left, pausing on hover, with a fixed `LOG` label anchoring the
left edge.

---

## File rows

Three columns: glyph (fixed width), name, size (right-aligned).

Folders use a solid `█` in the accent; files a hollow `▫` in mid. Folder names
render at bright, file names at soft, sizes at mid. Rows alternate a faint accent
band. Selection is an accent wash with a left accent border and the name in white
with a glow. The weight separation is load-bearing for scannability.

---

## Settings screen

Replaces the files view inside the same tube, with the same scanlines and sweep,
in the same terminal vocabulary.

- **Header** — a phosphor `▸ SETTINGS` with an accent caret and a dim underline;
  the device name in mono at the right.
- **Sections** — each a bracketed `[NN]` accent marker, a glass title, and a
  trailing rule:
  1. ACCENT — the eight swatches
  2. DENSITY — three row-stack diagrams at their real spacings
  3. TYPEFACE — the face grid
  4. TUBE — dark / light
  5. THIS DEVICE — mode, downloads, mount path, concurrent transfers, forget
  6. USE SYSTEM FILE BROWSER — the optional gate mount (Linux client only)
- **Footer** — versions on the left, `HOLD ELYXR TO EXIT` on the right.

Nostalgia Mode, when enabled, adds a master toggle above the numbered sections
that gates the retro features; see [Nostalgia Mode](#nostalgia-mode).

---

## State

Persisted with `shared_preferences`. The bearer token is not stored here — it
lives in the keyring, never in the clear, never on screen.

```
view       files | settings                          transient
mode       TEXT | GRID                                persist
path       String, trove-relative, "" is root
sel        Set<String>
query      String
sort       NAME | SIZE | DATE
accent     red|amber|green|cyan|blue|purple|pink|mono persist
accentSat  double, the colour drag intensity          persist
monoL      double, the mono/white lightness           persist
termFont   the terminal face family                    persist
density    TIGHT | MID | ROOMY                         persist
dark       bool (tube: glow vs paper)                  persist
appMode    client | server                             persist
trove      bool — is the gate mount on                 persist
downloadDir / mountPath / atOnce / confirmDelete       persist
nostalgia  bool — Nostalgia Mode                        persist
sound      bool — Nostalgia Mode sounds                 persist
holding    bool, transient
```

---

## Error display

lymnal's `message` renders verbatim, attached to the action that failed — never
reworded, summarised, or dropped. `code` and `request_id` sit behind a details
toggle with a copy button.

Three failures lymnal cannot report, because the request never arrives, have fixed
messages:

- **Timeout** — "Can't reach <server>. It may be asleep or off." Retries every few
  seconds and resumes waiting work once it answers.
- **No tailnet** — "Tailscale isn't connected on this device."
- **401** — "This device is no longer approved." Offers to request access again.

---

## Nostalgia Mode

An optional mode, off by default, toggled at the top of Settings. It does not
change what elyxr does; it adds retro presentation, gated entirely by the toggle.
A separate Sound switch gates its sound effects.

- **Matrix screensaver** — after ~120s idle, the tube fades to falling glyphs in
  the accent colour; any input dismisses it.
- **Cursor trail** — fading accent-coloured ghost arrows follow the pointer
  (desktop).
- **Crosshair** — the pointer becomes a crosshair over the file browser (desktop).
- **Transfer HUD** — a terminal-log readout near the top of the tube narrating
  real activity (link-up, uploads, downloads) with block progress bars.
- **Snake** — tapping the wordmark seven times opens a Snake game on the tube,
  steered by arrow keys / WASD or by swipe.
- **Nonsense button** — a small unmarked control on the bottom rail that floats a
  brief, purposeless message over the tube.
- **Sounds** — retro effects on key events (connect, transfers, delete, pairing,
  toggles), gated by the Sound switch.
