# Nostalgia Mode

The optional layer. None of it touches your files, your transfers, or the trove.
Core behaviour is in [SPECS.md](SPECS.md); the core look is in
[DESIGN.md](DESIGN.md).

## The shape of it

Three levels, at the top of Settings above the numbered sections. Every toggle
persists.

```
NOSTALGIA MODE                    off by default
  DEMO MODE                       revealed by Nostalgia; off by default
    SCREENSAVER                   revealed by Demo Mode; on
    LIGHTSHOW                     revealed by Demo Mode; on
    OSCILLOSCOPE                  revealed by Demo Mode; on
    SOUNDTRACK                    revealed by Demo Mode; on
```

**Nostalgia Mode** brings the cursor trail, the transfer log, Snake, the nonsense
button and the sound effects. Those five come as a set and have no individual
controls. Switching it on plays a laugh.

**Demo Mode** holds the four things below it. They are what Demo Mode *is*, so
with Demo Mode off there is no screensaver, no lightshow, no oscilloscope and no
soundtrack, and Nostalgia Mode is the five features above.

The four are on by default, so switching Demo Mode on gives you the whole thing at
once and turning one off is a deliberate act. Nothing forces a pairing: the
screensaver without the lightshow, or the oscilloscope without either, is a valid
combination.

Switching Nostalgia Mode off stops the soundtrack after a three-second grace
period, so a quick toggle back on doesn't cut the music. A trove stream is left
playing either way.

The settings page never lists what any of this does. Long-pressing the
`NOSTALGIA MODE` label shows the list.

---

## Rules the layer holds to

- It never touches a file or a transfer.
- It never hijacks the player. If something is already playing, nothing
  auto-starts and nothing stops it.
- It never invents data. The transfer log reads real transfer state.
- Every toggle persists.
- Nothing on the settings page narrates the features.

---

# Nostalgia Mode features

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

---

# Demo Mode features

Each has its own toggle, revealed while Nostalgia Mode and Demo Mode are both on.

## Screensaver

After 30 seconds without interaction the tube falls to black and glyphs rain down
in the accent colour, easing in over about 1.2 seconds.

Half-width katakana, digits and a few symbols on an 11.5px grid. Eighty columns
are precomputed once from a fixed seed, so the rain is the same every session and
stable frame to frame: each column has its own speed (6–22 cells per second),
start offset, and tail length (8–23 cells). The leading glyph is the bright
phosphor; the tail fades behind it. Glyphs flip occasionally as a column falls.

The rain covers the whole tube. No hole is cut in it.

The music player is drawn over the rain as content only — the title, the scope
trace, the transport, the progress bar — with no panel, no border and no dimming.
Its position is tied to the real player rather than calculated, so the copy lands
on the original exactly. The title block hangs above it and grows upward, so a long
title or a large text scale takes the room it needs.

- A click anywhere on the rain dismisses it.
- A click on the player is exempt. Using the transport doesn't dismiss the rain.
- The wheel anywhere over the rain sets volume.
- Moving the pointer or scrolling restarts the idle countdown but never dismisses
  the rain once it is up.

With the screensaver off, the tube never falls to the rain and the idle countdown
does not run.

## Lightshow

The inside edge of the tube strobes on the beat.

The ring follows the tube outline, including the two bottom corners where the
outline scoops around the speaker cradles. Two passes flash together: a wide
blurred bloom that spills onto the glass, and a thin crisp line on the edge
itself. The low bands drive it with an instant attack and a fast decay, so each
hit reads as a flash rather than a bright spot travelling around. The hardest
hits lift the colour from the accent toward the bright phosphor. A faint baseline
keeps the edge present between beats.

When nothing is playing it fades to nothing and stops repainting.

## Oscilloscope

The strip of glass between the two speaker cradles carries a scope trace. Its band
is derived from the cradles' widest reach, not their bottom-edge crossing, so the
trace can never slide under the metal.

With nothing playing it is a single faint centre line at the accent. With audio it
draws the waveform at the play head: 128 points averaged from a 512-sample window,
peak-normalised with a fast attack and a slow release so quiet passages stay
visible without a silent one filling with noise.

The trace is mirrored about the midpoint between the two speakers. Both halves fade
to nothing at their outer ends.

The window start is chosen by a trigger rather than the buffer start: it arms below
a small negative threshold, then fires on the next upward zero crossing. That holds
the waveform still instead of letting it skate sideways frame to frame.

With the oscilloscope off, the strip between the cradles is empty glass. The corner
speaker cones are not part of this toggle — they move to the audio at all times.

## Soundtrack

The built-in keygen soundtrack becomes the auto-playing music source:

- Switching Nostalgia Mode on, with Demo Mode and Soundtrack already on, starts the
  soundtrack once the opening laugh has finished, and only if nothing is playing.
- Switching Demo Mode on starts it immediately, unless something is playing.
- Switching Soundtrack on starts it immediately, unless something is playing.
  Switching it off stops it and leaves a trove stream alone.

While it plays, the soundtrack advances to a random different track every time one
ends. This is separate from the player's own shuffle control and never changes it
or the player's default order.
