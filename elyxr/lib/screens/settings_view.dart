// The settings screen, reached only by holding the wordmark. Replaces the files
// view inside the same tube, with the same scanlines and sweep. Numbered
// sections, an inverted accent header, and HOLD ELYXR TO EXIT in the footer.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../design/text.dart';
import '../design/tokens.dart';
import '../state/session.dart';
import '../state/settings.dart';
import '../state/music.dart';
import '../state/sound.dart';
import '../util/platform_caps.dart';
import '../state/updater.dart';
import '../util/device.dart';
import 'server_view.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final p = settings.palette;

    return DefaultTextStyle(
      style: glass(20, p.bright, height: 1.32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Terminal header: a phosphor title with an accent caret and a dim
          // underline — the same restrained console vocabulary as the files
          // view, not an inverted slab.
          Container(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.dim)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('▸',
                    style: glass(23, p.a).copyWith(
                        shadows: [Shadow(color: p.a, blurRadius: 10)])),
                const SizedBox(width: 8),
                Text('SETTINGS',
                    style: glass(26, p.bright).copyWith(
                        shadows: [Shadow(color: p.aAlpha(0.7), blurRadius: 9)])),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('THIS DEVICE', style: glass(13, p.mid)),
                    Text(session.serverName ?? deviceName(),
                        style: mono(12, p.bright, weight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(15, 13, 15, 0),
              children: [
                // The master switch for all the retro whimsy. Pinned at the top,
                // above everything numbered, so it reads as the mode gate it is.
                _NostalgiaRow(palette: p),
                const SizedBox(height: 13),
                // The music player lives on the first page (always visible), not
                // here — Settings never hosts it.
                // On the server device, its controls (pairing, limits, recent
                // problems) live here in Settings, since the tube now shows the
                // trove's files like every other device.
                if (settings.appMode == AppMode.server) ...[
                  ServerControls(palette: p),
                  const SizedBox(height: 16),
                ],
                _section(p, '01', 'ACCENT', _AccentPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '02', 'DENSITY', _DensityPicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '03', 'TYPEFACE', _FacePicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '04', 'TUBE', _TubePicker(palette: p)),
                const SizedBox(height: 13),
                _section(p, '05', 'THIS DEVICE', _DeviceRows(palette: p)),
                // A client can surface the trove as a real folder (the optional
                // gate mount) — Linux only, off by default. Kept last.
                if (settings.appMode == AppMode.client && Platform.isLinux) ...[
                  const SizedBox(height: 13),
                  _section(p, '06', 'USE SYSTEM FILE BROWSER', _GateRow(palette: p)),
                ],
                const SizedBox(height: 16),
                // Buried at the very bottom, unnumbered, undocumented: a dev
                // escape hatch to unlock the fixed window's size. In-memory only
                // (never saved, off on every launch). Not a listed feature.
                const SizedBox(height: 44),
                _ResizeRow(palette: p),
                const SizedBox(height: 8),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.dim))),
            padding: const EdgeInsets.fromLTRB(15, 9, 15, 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('ELYXR 0.9 · lymnal 0.9', style: mono(10, p.foot)),
                Text('HOLD ELYXR TO EXIT', style: chassis(10, p.mid, spacing: 0.1)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(Palette p, String num, String title, Widget body) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              children: [
                // A bracketed phosphor marker, not a filled chip — a terminal
                // section token in the accent colour.
                Text('[$num]',
                    style: mono(12, p.a, weight: FontWeight.w600)),
                const SizedBox(width: 9),
                Text(title, style: glass(17, p.bright)),
                const SizedBox(width: 9),
                Expanded(
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [p.dim, p.dim.withValues(alpha: 0)]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          body,
        ],
      );
}

/// The buried, undocumented resize escape hatch. Understated on purpose — it
/// reads as a stray line, not a feature. Flips the in-memory allowResize flag
/// (never saved) and applies it straight to the window. Off on every launch.
class _ResizeRow extends StatelessWidget {
  final Palette palette;
  const _ResizeRow({required this.palette});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final p = palette;
    final on = s.allowResize;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final v = !on;
        s.allowResize = v;
        try {
          await windowManager.setResizable(v);
          await windowManager.setMaximizable(v);
        } catch (_) {}
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text('allow window resizing', style: glass(13, p.foot)),
            ),
            Container(
              width: 26,
              height: 14,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: p.mv1,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? p.a : p.mb,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Nostalgia Mode master switch (and, once it's on, the sound sub-switch).
/// It gates every retro feature — the screensaver, cursor trail, minigame,
/// sounds. Pinned at the top of settings.
class _NostalgiaRow extends StatelessWidget {
  final Palette palette;
  const _NostalgiaRow({required this.palette});

  Widget _toggle(Palette p, bool on) => Container(
        width: 34,
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: p.mv1,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? p.a : p.mb,
            boxShadow: on ? [BoxShadow(color: p.a, blurRadius: 6)] : null,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final p = palette;
    final on = s.nostalgia;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () {
            final now = !on;
            s.nostalgia = now;
            final sound = context.read<SoundController>();
            sound.toggle(now);
            final music = context.read<MusicController>();
            if (now) {
              // Switching on: the laugh plays (always, stacking). The built-in
              // easter-egg soundtrack only auto-starts if nothing is already
              // playing — if the player is live (a track the user picked, or a
              // trove stream), Nostalgia leaves it alone rather than yanking it
              // back to track 0. Cancel any pending auto-stop from a recent off.
              music.cancelBuiltInStop();
              final laughDone = sound.laugh();
              // Opening laugh: let it land clean, then bring the soundtrack in
              // once it's done — but only when nothing was already playing. Rapid
              // re-toggles find the music live, skip this, and just stack another
              // laugh, so the stacking-laugh bit stays intact.
              if (!music.active) {
                laughDone.then((_) {
                  if (s.nostalgia && !music.active) music.startBuiltIn();
                });
              }
            } else {
              // Switching off: after a 3s grace period, stop the easter-egg
              // soundtrack (but leave a user's trove stream playing).
              music.scheduleBuiltInStop();
            }
          },
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text('◈', style: glass(20, on ? p.a : p.foot)),
                const SizedBox(width: 9),
                // What it does lives in a long-press popup on the label itself —
                // no spelled-out list on the page, no narration of the off state.
                // Long-press to reveal; hover never triggers it (the huge
                // waitDuration effectively disables the hover trigger, so only
                // triggerMode.longPress shows it).
                Tooltip(
                  message: 'Matrix screensaver\nCursor trail\nTransfer log\n'
                      'Snake (wordmark ×7)\nNonsense button\nSound effects\n'
                      'Auto-plays the soundtrack',
                  triggerMode: TooltipTriggerMode.longPress,
                  waitDuration: const Duration(days: 3650),
                  showDuration: const Duration(seconds: 6),
                  decoration: BoxDecoration(
                    color: p.tubeBg,
                    border: Border.all(color: p.a.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: glass(14, p.soft),
                  // Uses glass() (the swappable terminal face), not chassis(),
                  // so it re-skins with the chosen font like everything else on
                  // the glass — it was the one label stuck on the fixed face.
                  child: Text('NOSTALGIA MODE',
                      style: glass(16, on ? p.bright : p.mid, spacing: 0.16)),
                ),
                const Spacer(),
                _toggle(p, on),
              ],
            ),
          ),
        ),
        // The only sub-control: silence the sound effects without leaving the
        // mode. No feature list — that's in the label's hover popup.
        if (on)
          GestureDetector(
            onTap: () => s.sound = !s.sound,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 29, top: 3, bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(s.sound ? 'Sound on' : 'Sound off',
                        style: glass(15, p.mid)),
                  ),
                  _toggle(p, s.sound),
                ],
              ),
            ),
          ),
        Container(height: 1, color: p.dim),
      ],
    );
  }
}

/// The "Use System File Browser" switch: turns the optional gate mount on and
/// off. Off means the trove lives in elyxr; on also surfaces it as a folder in
/// the file manager.
class _GateRow extends StatelessWidget {
  final Palette palette;
  const _GateRow({required this.palette});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsController>();
    final p = palette;
    final on = s.trove;
    return GestureDetector(
      onTap: () => s.trove = !on,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Expanded(
            child: Text(
              on
                  ? 'On — the trove also appears as a folder in your file manager, on the Desktop.'
                  : 'Off — the trove lives in elyxr. Turn this on to also open it as a folder in your file manager.',
              style: glass(15, p.mid),
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 34,
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: p.mv1,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? p.a : p.mb,
                boxShadow: on ? [BoxShadow(color: p.a, blurRadius: 6)] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentPicker extends StatelessWidget {
  final Palette palette;
  const _AccentPicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    // Watch so the tapped swatch's mini-tube (and the whole app) update live as
    // it's dragged.
    final settings = context.watch<SettingsController>();
    return Row(
      children: [
        for (final accent in Accent.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // A single press picks the phosphor; dragging up/down pushes its
                // intensity — saturation (and glow) for a colour, lightness for
                // mono. Nothing else: no double-tap. The whole tube responds live.
                onTapDown: (_) => settings.accent = accent,
                onVerticalDragUpdate: (d) {
                  final up = -(d.primaryDelta ?? 0);
                  if (accent == Accent.mono) {
                    settings.monoL = settings.monoL + up * 0.0026;
                  } else {
                    settings.accentSat = settings.accentSat + up * 0.006;
                  }
                },
                child: _swatch(accent, accent == settings.accent, palette, settings),
              ),
            ),
          ),
      ],
    );
  }

  /// Each swatch is a miniature tube in that colour, previewing the machine
  /// rather than showing a paint chip. The selected one shows at the current
  /// drag intensity; the rest sit at their neutral default.
  Widget _swatch(Accent accent, bool on, Palette base, SettingsController s) {
    final sp = Palette(accent, base.dark,
        sat: on ? s.accentSat : 1.0,
        monoL: accent == Accent.mono && on ? s.monoL : null);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 7),
          decoration: BoxDecoration(
            color: base.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
            border: Border.all(color: on ? sp.a : base.dim),
            borderRadius: BorderRadius.circular(2),
            boxShadow: on ? [BoxShadow(color: sp.aAlpha(0.47), blurRadius: 15)] : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 4, width: double.infinity, color: sp.a.withValues(alpha: on ? 1 : 0.4)),
              const SizedBox(height: 5),
              FractionallySizedBox(
                widthFactor: 0.46,
                alignment: Alignment.centerLeft,
                child: Container(height: 4, color: sp.a.withValues(alpha: on ? 0.55 : 0.22)),
              ),
              const SizedBox(height: 5),
              SizedBox(
                height: 10,
                child: Row(
                  children: List.generate(
                    8,
                    (i) => Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(right: 1),
                        color: sp.a.withValues(alpha: i < 5 ? (on ? 0.95 : 0.4) : 0.13),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Shrink the label to fit its narrower column (8 accents now) rather
        // than overflow — a smart squish, not a clip.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(accent.label,
              style: chassis(10, on ? base.bright : base.mid, spacing: 0.1)),
        ),
      ],
    );
  }
}

class _DensityPicker extends StatelessWidget {
  final Palette palette;
  const _DensityPicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.read<SettingsController>();
    return Row(
      children: [
        for (final d in Density.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => settings.density = d,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
                        border: Border.all(color: d == settings.density ? p.a : p.dim),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          d == Density.tight ? 6 : (d == Density.mid ? 4 : 3),
                          (_) => Padding(
                            padding: EdgeInsets.symmetric(
                                vertical: d == Density.tight ? 1 : (d == Density.mid ? 2.5 : 4.0)),
                            child: Container(
                                height: 3,
                                color: (d == settings.density ? p.a : p.mid)
                                    .withValues(alpha: d == settings.density ? 0.9 : 0.5)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(d.label,
                        style: chassis(10, d == settings.density ? p.bright : p.mid, spacing: 0.1)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The terminal-face picker: one chip per available face, each previewing its
/// own font so you read the choice in the choice. Swapping re-skins the whole
/// terminal live. Add a face by dropping a TTF in assets/fonts/, declaring it in
/// pubspec.yaml, and adding a row to kTermFaces — it shows up here automatically.
class _FacePicker extends StatefulWidget {
  final Palette palette;
  const _FacePicker({required this.palette});

  @override
  State<_FacePicker> createState() => _FacePickerState();
}

class _FacePickerState extends State<_FacePicker> {
  final _scroll = ScrollController();
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_sync);
    // After first layout the controller knows its extent, so the arrows can show
    // whether there's anywhere to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  // A mouse can't drag a horizontal list and the wheel scrolls vertically, so
  // the side arrows are the way across: tap to nudge, hold to glide.
  void _press(int dir) {
    _step(dir);
    _hold?.cancel();
    _hold = Timer.periodic(const Duration(milliseconds: 16), (_) => _step(dir));
  }

  void _release() {
    _hold?.cancel();
    _hold = null;
  }

  void _step(int dir) {
    if (!_scroll.hasClients) return;
    final target =
        (_scroll.offset + dir * 14.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  bool get _canLeft => _scroll.hasClients && _scroll.offset > 0.5;
  bool get _canRight =>
      _scroll.hasClients && _scroll.offset < _scroll.position.maxScrollExtent - 0.5;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final settings = context.watch<SettingsController>();
    // One fixed-height row that scrolls sideways — so however many faces there
    // are (the built-ins plus any dev-dropped fonts in assets/fonts/custom/),
    // the section keeps its shape and nothing below it moves. termFaces is the
    // live list: built-ins + custom.
    final faces = termFaces;
    return SizedBox(
      height: 67,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Manual refresh: re-scan the fonts folder on disk for a face you've
          // dropped in but not committed/rebuilt yet — a live preview.
          _tile(p, 40, Icon(Icons.refresh, size: 20, color: p.mid), 'SCAN', false,
              () => context.read<SettingsController>().reloadFonts()),
          const SizedBox(width: 8),
          _arrow(p, left: true),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.hardEdge,
              itemCount: faces.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final face = faces[i];
                final on = settings.termFont == face.family;
                return SizedBox(
                  width: 68,
                  child: _tile(
                    p,
                    68,
                    Text('Aa',
                        style: TextStyle(
                          fontFamily: face.family,
                          fontSize: 24,
                          color: on ? p.a : p.foot,
                          shadows: on ? [Shadow(color: p.a, blurRadius: 10)] : null,
                        )),
                    face.label,
                    on,
                    () => settings.termFont = face.family,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          _arrow(p, left: false),
        ],
      ),
    );
  }

  /// A specimen/utility tile: a 44-tall box over a caption, so SCAN, the faces,
  /// and (visually) the arrows all share one shape.
  Widget _tile(Palette p, double width, Widget glyph, String label, bool on,
          VoidCallback onTap) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
                  border: Border.all(color: on ? p.a : p.dim),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: glyph,
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, style: chassis(9.5, on ? p.bright : p.mid, spacing: 0.08)),
              ),
            ],
          ),
        ),
      );

  Widget _arrow(Palette p, {required bool left}) {
    final enabled = left ? _canLeft : _canRight;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _press(left ? -1 : 1) : null,
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: Container(
        width: 24,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3),
          border: Border.all(color: enabled ? p.a : p.dim),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(left ? '‹' : '›', style: glass(22, enabled ? p.a : p.foot)),
      ),
    );
  }
}

class _TubePicker extends StatelessWidget {
  final Palette palette;
  const _TubePicker({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.read<SettingsController>();
    Widget half(String label, String glyph, bool on, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on
                          ? (p.dark ? const Color(0xFF030604) : const Color(0xFFf2f7f3))
                          : (p.dark ? const Color(0xFF0d1510) : const Color(0xFFd8e2da)),
                      border: Border.all(color: on ? p.a : p.dim),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(glyph,
                        style: glass(24, on ? p.a : p.foot).copyWith(
                            shadows: on ? [Shadow(color: p.a, blurRadius: 10)] : null)),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: chassis(10, on ? p.bright : p.mid, spacing: 0.1)),
                ],
              ),
            ),
          ),
        );
    return Row(
      children: [
        half('DARK', '●', settings.dark, () => settings.dark = true),
        half('LIGHT', '○', !settings.dark, () => settings.dark = false),
      ],
    );
  }
}

class _DeviceRows extends StatelessWidget {
  final Palette palette;
  const _DeviceRows({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final settings = context.watch<SettingsController>();
    final session = context.watch<SessionController>();
    final update = context.watch<UpdateController>();

    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: glass(20, p.mid)),
              const SizedBox(width: 12),
              // The value can be long (an Android downloads path); let it take
              // the remaining width and clip to one line instead of overflowing.
              Flexible(child: Align(alignment: Alignment.centerRight, child: value)),
            ],
          ),
        );

    return Column(
      children: [
        // Server mode is desktop only — a phone has no local trove to host.
        if (Caps.isDesktop)
          row(
            'MODE',
            GestureDetector(
              onTap: () => settings.appMode =
                  settings.appMode == AppMode.server ? AppMode.client : AppMode.server,
              behavior: HitTestBehavior.opaque,
              child: Text('${settings.appMode.name.toUpperCase()}  ⇄', style: glass(20, p.a)),
            ),
          ),
        if (Caps.isDesktop && settings.appMode == AppMode.server)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('Server controls are on the main screen (exit settings).',
                style: glass(14, p.foot)),
          ),
        row(
            'DOWNLOADS',
            Text(settings.downloadDir,
                style: glass(20, p.bright),
                softWrap: false,
                overflow: TextOverflow.ellipsis)),
        // The mount path only matters where the gate can run (a Linux client);
        // in server mode there's no mount, so it isn't shown.
        if (settings.appMode == AppMode.client && Platform.isLinux)
          row(
            'MOUNT AT',
            GestureDetector(
              onTap: () async {
                final v = await _editMountPath(context, p, settings.mountPath);
                if (v != null && v.trim().isNotEmpty) settings.mountPath = v.trim();
              },
              behavior: HitTestBehavior.opaque,
              child: Text('${settings.mountPath}  ✎', style: glass(20, p.a)),
            ),
          ),
        row('AT ONCE', Text('${settings.atOnce} transfers', style: glass(20, p.bright))),
        // Update this device by hand — the same install the service runs on its
        // own when the server moves ahead. Here so it's reachable in any mode,
        // not just on the server. Reflects the update's state while it runs.
        _updateRow(context, p, update),
        if (session.serverName != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: () => _confirmForget(context, session),
              behavior: HitTestBehavior.opaque,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('▸ FORGET ${session.serverName!.toUpperCase()}',
                    style: glass(19, const Color(0xFFf5b942))),
              ),
            ),
          ),
      ],
    );
  }

  /// A plain "update this device" action — no version numbers, just what it's
  /// doing: tap to update, then UPDATING… while it runs, or an amber retry with
  /// the reason if it couldn't finish.
  Widget _updateRow(BuildContext context, Palette p, UpdateController u) {
    final busy = u.stage == UpdateStage.updating || u.stage == UpdateStage.waitingForUpload;
    final failed = u.stage == UpdateStage.failed;
    final text = switch (u.stage) {
      UpdateStage.idle => '▸ UPDATE THIS DEVICE',
      UpdateStage.updating => '▸ UPDATING…',
      UpdateStage.waitingForUpload => '▸ FINISHING UPLOAD, THEN UPDATING…',
      UpdateStage.failed => '▸ RETRY UPDATE',
    };
    final color = failed ? const Color(0xFFf5b942) : (busy ? p.mid : p.a);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: busy
                ? null
                : () => failed
                    ? context.read<UpdateController>().retry()
                    : context.read<UpdateController>().updateNow(),
            behavior: HitTestBehavior.opaque,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(text, style: glass(19, color)),
            ),
          ),
          if (failed && u.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(u.error!, style: glass(14, const Color(0xFFf5b942))),
            ),
        ],
      ),
    );
  }

  Future<String?> _editMountPath(BuildContext context, Palette p, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.tubeBg,
        title: Text('Mount the trove at', style: glass(18, p.bright)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: glass(18, p.bright),
          cursorColor: p.a,
          decoration: InputDecoration(hintText: '~/trove', hintStyle: glass(16, p.foot)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('CANCEL', style: chassis(11, p.mid))),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text('SET', style: chassis(11, p.a))),
        ],
      ),
    );
  }

  void _confirmForget(BuildContext context, SessionController session) {
    final p = palette;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.tubeBg,
        title: Text('Forget ${session.serverName}?', style: glass(20, p.bright)),
        content: Text(
          'This device will need to be approved again afterwards. Nothing in the trove is touched, and nothing changes on the server.',
          style: glass(16, p.soft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: chassis(11, p.mid)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              session.forget();
            },
            child: Text('FORGET', style: chassis(11, p.a)),
          ),
        ],
      ),
    );
  }
}
