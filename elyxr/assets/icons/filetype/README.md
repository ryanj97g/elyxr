# File-type glyphs

One SVG per `FileKind` (see `lib/design/file_icons.dart`). Drop them in here,
named **exactly** after the kind, and flip that kind's line in `kFileMarks` to
`FileMark.svg()` — the widget derives the filename from the kind, so there is no
path to typo.

```
folder.svg        audio.svg         video.svg        image.svg
document.svg      spreadsheet.svg   presentation.svg archive.svg
code.svg          text.svg          data.svg         font.svg
disk.svg          app.svg           unknown.svg
```

A kind with no file yet keeps the terminal character it has now, so the set can
land a few at a time without the grid looking half-finished. `unknown.svg` here is
a placeholder standing in for the small square — replace it.

## Drawing them

- **Canvas** `viewBox="0 0 24 24"`, with the artwork inside a 20×20 live area
  (2px of clear space on every side). That matches the optical size of the
  characters they replace and of the Material icons on the music deck.
- **Monochrome, and colour does not matter.** Every visible pixel gets repainted
  from the palette at draw time via `BlendMode.srcIn`, so whatever fill you
  export with is discarded. Only the *shape* and the *transparency* survive.
  Don't spend time picking a colour, and don't build a set that relies on two
  tones — a second tone will flatten into the first.
- **Filled shapes, not strokes.** Convert strokes to outlines before exporting,
  or they'll thin out at small sizes and won't match each other. Use
  `fill-rule="evenodd"` for anything hollow (see `unknown.svg`).
- **One weight across the set.** These sit next to each other in a grid, so a
  heavier `audio` than `video` reads as a mistake rather than as emphasis.
- **No `<style>` blocks, no CSS classes, no embedded rasters.** Plain `<path>`
  geometry renders fastest and tints reliably.

## If a .ttf glyph font turns up instead

Better still, and it needs no asset folder at all. Declare the family in
`pubspec.yaml`, expose each glyph as `IconData(0xNNNN, fontFamily: 'YourFamily')`,
and use `FileMark.icon(...)` instead of `FileMark.svg()`. Both forms are supported
side by side, so a font can replace these one kind at a time too.
