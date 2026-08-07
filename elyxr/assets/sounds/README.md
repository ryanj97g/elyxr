# Nostalgia Mode sounds

Drop retro sound effects here as `.wav` (or `.ogg`) files, named exactly as
below. They play only in Nostalgia Mode with the Sound switch on. See
`lib/state/sound.dart` for the one-step activation (it needs a local build,
because the audio plugin can't be validated in CI).

| file | plays when |
|---|---|
| `connect.wav` | the link to the server comes up |
| `upload.wav` | an upload finishes |
| `download.wav` | a download finishes |
| `delete.wav` | a delete is confirmed |
| `pair.wav` | pairing is activated |
| `on.wav` | Nostalgia Mode / Sound turned on |
| `off.wav` | Nostalgia Mode / Sound turned off |
| `hover.wav` | (optional) hovering a control |

Keep them short (a few hundred ms) and quiet. CC0 / royalty-free only.
