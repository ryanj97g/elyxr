# Custom terminal fonts (dev drop-in)

Drop a `.ttf` or `.otf` here, commit it, rebuild — and it shows up in
Settings → TYPEFACE automatically. No pubspec edit per font.

- The font's **family name is the filename** without its extension
  (`MyFont.ttf` → family "MyFont", shown as "MYFONT").
- Files that fail to load are skipped silently.
- This folder is tracked, so fonts added here ship to every device (like the
  music). It's a dev folder — end users don't manage it.

Number glyphs (and any other glyph) are up to the font itself; a font that
lacks digits will still lack them here. Pick fonts that cover what you need.
