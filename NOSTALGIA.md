# Nostalgia Mode

The optional layer. None of it touches your files, your transfers, or the trove.
Core behaviour is in [SPECS.md](SPECS.md); the core look is in
[DESIGN.md](DESIGN.md).

One toggle, at the top of Settings above the numbered sections. It persists. The
page never lists what it does; long-pressing the `NOSTALGIA MODE` label shows the
list.

Switching it on plays a laugh. Switching it off stops the built-in soundtrack
after a three-second grace period, so a quick toggle back on doesn't cut the
music; a trove stream is left playing either way.

---

## Rules the layer holds to

- It never touches a file or a transfer.
- It never hijacks the player. If something is already playing, nothing
  auto-starts and nothing stops it.
- It never invents data. The transfer log reads real transfer state.
- Everything is one toggle, and that toggle persists.
- Nothing on the settings page narrates the features.

---

## Matrix screensaver

After 30 seconds without interaction the tube falls to black and glyphs rain down
in the accent colour, easing in over about 1.2 seconds.

Half-width katakana, digits and a few symbols on an 11.5px grid. Eighty columns
are precomputed once from a fixed seed, so the rain is the same every session and
stable frame to frame: each column has its own speed (6–22 cells per second),
start offset, and tail length (8–23 cells). The leading glyph is the bright
phosphor; the tail fades behind it. Glyphs flip occasionally as a column falls.

The rain covers the whole tube. No hole is cut in it.

The music player is drawn over the rain as content only — the title, the
oscilloscope, the transport, the progress bar — with no panel, no border and no
dimming. Its position is tied to the real player rather than calculated, so the
copy lands on the original exactly. The title block hangs above it and grows
upward, so a long title or a large text scale takes the room it needs.

- A click anywhere on the rain dismisses it.
- A click on the player is exempt. Using the transport doesn't dismiss the rain.
- The wheel anywhere over the rain sets volume.
- Moving the pointer or scrolling restarts the idle countdown but never dismisses
  the rain once it is up.

## Cursor trail

Ghost pointer arrows fade behind the pointer in the accent colour. Each lingers
0.55 seconds, one is dropped every 7 pixels of travel, and at most 40 exist at
once. It feeds on hover events, so on touch it draws nothing.

## Transfer log

A small terminal readout near the top of the tube, shown only when there is
something to say. It narrates the link coming up and up to four active transfers,
each as a direction arrow, the file name, a twelve-cell block bar, and a status:
a percentage while running, or `QUEUED`, `PAUSED`, `ERR`, `OK`.

Tapping it during a transfer makes it stutter sideways for about a third of a
second. The transfer is unaffected. It is not shown in Settings.

## Snake

Tap the wordmark seven times. The game takes over the tube, above the
screensaver.

A 16 × 26 grid, one step every 150 milliseconds. Arrow keys or WASD on a
keyboard, swipe on touch. A reversal straight into yourself is ignored rather
than fatal. The head is the bright phosphor, the body the accent, the food a
glowing dot at soft. Hitting a wall or yourself ends the run and shows the score;
tap to restart, `EXIT ✕` or Esc to leave.

## Nonsense button

An unmarked `◦` on the bottom rail. Pressing it floats one line over the tube for
about two seconds — fading in, bobbing, fading out — then removes itself. The
lines come from a file baked into the build, with a built-in list as fallback if
that file is missing. It touches nothing.

## Sound effects

Short clips on the link coming up, an upload finishing, a download finishing, a
delete, a pairing request, the toggle itself, and hover.

Each clip plays on its own throwaway player, so rapid events stack instead of
cutting each other off, and the player disposes itself when the clip ends. A
missing file or an absent audio device is swallowed and never reaches the app.

The laugh on switching Nostalgia Mode on plays regardless of the effects.

## Edge light

The inside edge of the tube strobes on the beat.

The ring follows the tube outline, including the two bottom corners where the
outline scoops around the speaker cradles. Two passes flash together: a wide
blurred bloom that spills onto the glass, and a thin crisp line on the edge
itself. The low bands drive it with an instant attack and a fast decay, so each
hit reads as a flash rather than a bright spot travelling around. The hardest
hits lift the colour from the accent toward the bright phosphor. A faint baseline
keeps the edge present between beats.

When nothing is playing it fades to nothing and stops repainting.

---

## 2000's DEMO MODE

A sub-toggle, revealed under Nostalgia Mode while Nostalgia Mode is on. Off by
default. It persists.

It makes the built-in soundtrack the auto-playing source:

- Switching Nostalgia Mode on with demo mode already on starts the soundtrack
  once the opening laugh has finished, and only if nothing is playing.
- Switching demo mode on starts the soundtrack immediately, unless something is
  playing.
- Switching demo mode off stops the soundtrack and leaves a trove stream alone.

While it is on, the soundtrack advances to a random different track every time
one ends. This is separate from the player's own shuffle control and never
changes it or the player's default order.
