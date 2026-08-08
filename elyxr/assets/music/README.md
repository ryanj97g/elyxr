# Easter-egg soundtrack (baked in)

These tracks are part of the app — the cracked-keygen easter egg. Nostalgia Mode
auto-plays them through the always-present music player on the first page. This
is **not** a user drop-folder; end users never see or edit it.

Whatever is committed here becomes the playlist, in filename order. The shown
title is the filename with the extension stripped and underscores/dashes turned
to spaces (`01_crack_intro.xm` → "01 crack intro").

Formats: `.ogg` / `.mp3` / `.wav` / `.flac` play directly; tracker modules
(`.xm` / `.mod` / `.s3m` / `.it`) are rendered to PCM on load (via openmpt123),
so they play too — with the FFT visualizer reacting to them like anything else.
