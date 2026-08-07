# Elyxr — visual design

How the app *looks and feels*. Behaviour — the network, sync, updates — is in
[SPECS.md](SPECS.md); this file is appearance and interaction only.

Exact colours and sizes are **not** duplicated here — they live in the code, and
this doc would only rot beside them. The source of truth is:

- `elyxr/lib/design/oklch.dart` — the colour engine (the maths).
- `elyxr/lib/design/tokens.dart` — every accent, the palette, densities, faces.
- `elyxr/lib/design/text.dart` — the three type roles and their scales.

What lives here instead are the **laws** (the things that must stay true), the
**why** behind choices that look arbitrary, and the **interactions** — especially
the hidden, gestural ones you can't find by reading the widget tree.

---

## The idea

Elyxr looks like a **piece of hardware**: a tinted metal chassis with a phosphor
CRT tube recessed into it.

**Everything behind the glass is the terminal. Everything on the metal is a
physical control.** That division holds everywhere and is the whole design. When
in doubt about where something goes or what font it wears, ask which side of the
glass it's on.

Fixed **440 × 884**, portrait, not resizable in v1.

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

The chassis is a near-vertical metal gradient with a **machined bevel**: a bright
highlight hairline along the top edge and a recessed dark hairline along the
bottom, so the panel reads as raised, brushed metal rather than a flat slab. The
tube is recessed with a bezel ring and a soft inner vignette.

Both rails are drag handles — grab the metal to move the window. The tube can't
be one, or you couldn't scroll or click files. (The "Use System File Browser"
toggle used to live on the bottom rail; it moved into Settings, since it's off by
default and Linux-only.)

---

## Color — the theme system

This is the heart of the design and the part that changed most from the first
draft. Colour is a **system, not a table**: every colour on screen — the glowing
tube, the paper terminal in light mode, and the metal chassis — is *computed* from
**one hue** by a perceptual (OKLCH) engine. Add an accent by writing one row of
four numbers; everything else follows. The engine is `oklch.dart` (pure Dart, no
Flutter, so the maths is unit-tested on its own against an oracle); `tokens.dart`
turns its ints into the palette.

### The law

**Everything on a screen is one colour.** The accent hue drives the phosphor
*and* the metal (which carries only a whisper of the hue — a tinted grey, never a
coloured chassis). If a screen ever looks like two colours fighting, that's a bug,
not a style choice.

### Why OKLCH, and the one trick that matters

A colour is asked for as **L** (perceptual lightness 0–1), **C** (chroma /
colourfulness), and **h** (hue angle in degrees). OKLCH is perceptually uniform,
so equal moves look equal across hues — unlike HSL, where "50% saturation" is a
vivid blue but a muddy yellow.

The trick that makes "one colour" hold: a hue can only be *so* colourful at a
given lightness before it leaves the sRGB gamut. Naively rendering an
out-of-gamut OKLCH value lets the display **gamut-map** it, which **drifts the
hue** — a deep blue slides to teal, a deep orange to red. So instead of asking for
a colour, you ask for a hue plus a chroma **budget**, and the engine returns *the
richest colour that is still true to that hue*. That clamp — not "OKLCH instead of
hex" — is the whole point.

### The engine (the maths)

**OKLab → linear sRGB.** Convert L,C,h to OKLab (`a = C·cos h`, `b = C·sin h`),
then the standard OKLab matrix: three linear combinations of L,a,b, each cubed,
then a 3×3 to linear-light R,G,B. (Exact coefficients in `oklch.dart::_linear`.)

**In gamut?** The colour fits sRGB if every linear channel is within `[0,1]`
(with a `0.001` slack).

**`maxChroma(l, h)`** — the richest in-gamut chroma for a lightness+hue, by a
**20-step binary search** over `C ∈ [0, 0.4]` (~20 gamut checks, cheap). This is
the primitive everything leans on.

**Encode.** Linear channel → 8-bit sRGB via the sRGB gamma companding
(`12.92·x` below `0.0031308`, else `1.055·x^(1/2.4) − 0.055`), clamped to 0–255.

**Two ways to render:**
- `oklchArgb(l, c, h)` — chroma used **as given** (may gamut-map/drift). Used only
  where chroma is already known-safe (e.g. the achromatic mono/white).
- `trueArgb(l, h, reqC)` = `oklchArgb(l, min(reqC, maxChroma(l, h)), h)` — the
  **clamp**. Requested chroma capped to the in-gamut ceiling, hue held. This is
  the default for everything hue-bearing.

**`accentChroma(chromaMul, maxCeil, sat)`** — the accent swatch's own chroma:

```
c = 0.13 · chromaMul · sat
c = max(c, 0.045)          # floor: never fully flat, but low enough to wash to grey
c = min(c, maxCeil)        # ceiling: the hue's chosen budget
```

**`lForC(h, targetC, hiL, loL)`** — a further primitive from the source system: the
lightest (or darkest) lightness that can still hold a target chroma for a hue —
the way you'd *homogenise* saturation across hues (a narrow-gamut blue rides to
whatever L lets it match a wide-gamut green). It's available in the engine but the
current palette pins lightnesses per role instead (below); it's here for when a
future role wants equal chroma across all accents.

### The accents — eight, spectrum order

Each is four numbers: `AccentSpec(hue, chromaMul, maxCeil, baseL)`. `mono` is the
white phosphor — achromatic, its intensity a lightness. Green is default.

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

(`tokens.dart` is canonical — these will be tuned; the *structure* is the durable
part.)

### The palette recipe

From one hue `h` and the accent's `maxCeil`, every role is a fixed lightness with
a chroma that's a fraction of the budget, rendered through `trueArgb` (so it's
always in-gamut). `wc`/`mc` are 1 for a colour accent, 0 for mono.

**Accent swatch** `a` = `trueArgb(baseL, h, accentChroma(...))` (mono:
`oklchArgb(monoL, 0, 0)`). **Ink** on the accent = dark (`L 0.24`) if the accent
is light (`>0.70`), else white.

**Metal** — hue at a *whisper* of chroma (`0.008–0.016`), same in both modes:
`m1 L.240 · m2 .160 · m3 .130` (gradient), `mb .300` (border), `mh .400`
(highlight), `mt .550` / `ml .860` (text), `mv1 .100` / `mv2 .210` (recess, vent).

**Phosphor — dark** (glowing tube): `bright L.88 @ 0.9·budget · soft .34@.55 ·
mid .66@1.0 · dim .44@.85 · foot .52@.70 · glow .60@1.0 · tube-bg L.085` (near
black). `bright`'s chroma is boosted by the drag (capped at ×1.5) so a punchier
accent also glows harder.

**Phosphor — light** (paper terminal): `bright L.28 · soft .42@.80 · mid .50@.80 ·
dim .80@.40 · foot .62@.60 · glow .55@1.0 · tube-bg L.940` (paper). Light mode is
fully hue-derived — not a special-cased green.

### The two drag axes

The accent swatch is **tactile** (see Interactions). Dragging changes intensity,
live, across the whole app:

- A **colour** accent drags **saturation _and_ glow together** — one motion makes
  the phosphor richer *and* brighter (`sat` feeds both `accentChroma` and the
  bright-glow boost). Range `0.25 – 3.2`: wide on purpose, so it washes most of
  the way to grey at the bottom and reaches the hue's true in-gamut peak at the
  top (the clamp keeps it from drifting there).
- **mono** drags **lightness** (`monoL`, `0.12 – 0.99`) — dim graphite to bright
  white.

Selecting a different accent resets its intensity to neutral — the drag is
per-accent, from a fresh phosphor.

### Tube overlays

Three distinct things live over the glass; **keep them distinct.**

- **Scanlines** — faint phosphor-tinted hairlines every 4px. The static "CRT
  texture." It does **not** move. (Rasterised to a cached layer so scaling the
  fixed chassis to the window resamples one texture instead of redrawing crisp
  lines every frame, which shimmered.)
- **Sweep** — a single thin scanner line crossing the whole tube top to bottom,
  **one quick pass every ~11 seconds**, near-translucent with the faintest glow.
  It is a *line that moves*, **not** a lit band dragged across the texture — that
  distinction was hard-won; the sweep must never light the texture.
- **Vignette + bloom** — a soft accent bloom at the centre falling to a gentle
  dark ring at the edges. A falloff, not a heavy black frame; corners stay
  legible.

---

## Type

Three faces, one job each — but the *terminal* face is now the user's to choose.

| Role (helper) | Job | Face |
|---|---|---|
| `chassis()` | Chassis labels, section markers, rail buttons | **Chakra Petch**, fixed |
| `glass()` | Everything on the glass — rows, readouts, settings | the **terminal face** |
| `mono()` | The ticker and readouts on the glass | the **terminal face** |

- **The terminal face is swappable** (Settings › TYPEFACE), from VT323 (default)
  through a dozen bundled faces. It governs `glass()` **and** `mono()` — the whole
  screen re-skins as one face. Add a face by dropping a TTF in `assets/fonts/`,
  declaring it in `pubspec.yaml`, and adding one row to `kTermFaces`.
- **The metal face (`chassis()`) never changes.** The `v2.0.5` badge on the rail
  is metal, so it uses the chassis face and stays put when the screen face swaps.
- **The ticker follows the terminal face.** The original design kept the ticker on
  a separate mono face and said "do not unify this." That was **deliberately
  overridden**: the ticker is part of the screen, so it wears the screen's face
  like everything else on the glass. (VT323 is a bitmap face and softens in
  motion; if you want a crisp monospace ticker, pick a monospace terminal face.)

One knob per role in `text.dart` scales every call site at once.

---

## Interactions

### Hold the wordmark — the settings screen

The only way in. Nothing marks the wordmark as pressable, and nothing should.

- **Press** — the wordmark tightens its tracking, lights to the accent with a
  glow, and a small bar beside it fills.
- **~250ms** — the tube swaps to settings. The wordmark stays lit the whole time
  you're in there. **Hold again** to return to files.
- **Release early** — reverts, nothing happens.

No settings button, tooltip, or first-run hint anywhere. This is intentionally
undiscoverable; the user was explicit about keeping it so.

### Tactile — hover on desktop, press on touch

Clickable surfaces light the **same** phosphor glow on every device: a mouse
*hovers* it, a finger *presses* it, both resolve to one lit state. Build touchable
things through this one abstraction (`Tactile`) so desktop and touch feel the
same; it's passive and never eats the underlying tap.

### The accent swatches

Each swatch is a **miniature tube** in that colour — it previews the machine, not
a paint chip. **Tap** to pick. **Drag** up/down to push intensity (saturation+glow
for a colour, lightness for mono). **Double-tap** to reset. The whole app responds
live as you drag.

### The typeface picker

A grid of faces, each chip rendering **its own font** so you read the choice in
the choice. Tap swaps the terminal face live.

### Density

TIGHT / MID / ROOMY. It is a **global text scale for the glass** (≈0.9 / 1.0 /
1.15), not padding alone — the whole terminal grows or tightens together, while
the metal rails keep their fixed physical size. Row padding still tracks density
for breathing room.

### TEXT / GRID

A rocker on the bottom rail. TEXT is the dense phosphor list (default); GRID is
3-across tiles. **Hidden while the settings screen is open** — it only drives the
file list, so it doesn't belong there. Persists.

### File rows

- **Single click** selects (a folder can be selected too, to delete or move).
- **Double-click** opens a folder, or previews a file.
- **Drag a file sideways out** of the window and it downloads to wherever you
  drop it; a vertical drag still scrolls.
- **Long-press** renames.

### The ticker

Scrolls right-to-left, pausing on hover, with a fixed `LOG` label anchoring the
left edge. Runs at a brisk loop (faster than the first draft).

---

## File rows

Three columns: glyph (fixed width), name, size (right-aligned).

Folders get a solid `█` in the accent; files a hollow `▫` in mid. Folder names
sit at **bright**, file names at **soft**, sizes at **mid**. Rows alternate a
faint accent band. Selection is an accent wash with a left accent border and the
name in white with a glow.

That hierarchy exists because an earlier version had every line the same weight
and was unreadable at a glance. **Keep the separation.**

---

## Settings screen

Replaces the files view inside the same tube — same scanlines, same sweep. It is
deliberately in the **same restrained terminal vocabulary** as the files view, so
the two don't feel like different apps.

- **Header** — a phosphor `▸ SETTINGS` with an accent caret and a dim underline,
  the device name in mono at the right. (Not the old inverted solid-accent band —
  that read like a designed app pane dropped into a terminal.)
- **Sections** — each a bracketed `[NN]` accent marker, a glass title, and a rule
  trailing off:
  1. **ACCENT** — the eight tactile swatches
  2. **DENSITY** — three row-stack diagrams at their real spacings
  3. **TYPEFACE** — the face grid
  4. **TUBE** — dark / light
  5. **THIS DEVICE** — mode, downloads, mount path, concurrent transfers, forget
  6. **USE SYSTEM FILE BROWSER** — the optional gate mount *(Linux client only)*
- **Footer** — versions on the left, `HOLD ELYXR TO EXIT` on the right.

---

## State

Persisted with `shared_preferences`. The bearer token is **never** here — it
lives in the keyring, never written in the clear, never shown on screen.

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
holding    bool, transient
```

---

## Error display

Show lymnal's `message` **word for word**, attached to the action that failed.
Never reword, summarize, or swallow. `code` and `request_id` go behind a details
toggle with a copy button.

Three failures lymnal cannot report, because the request never arrives:

- **Timeout** — "Can't reach <server>. It may be asleep or off." Retry every few
  seconds; resume everything waiting the moment it answers.
- **No tailnet** — "Tailscale isn't connected on this device." A distinct message.
- **401** — "This device is no longer approved." Offer to request access again.

---

## Not yet built

Specified, intended, not implemented:

- **Ticker hold-to-read** — press and hold a ticker message to open it as a
  wrapped, readable popup that stays open only while held.
