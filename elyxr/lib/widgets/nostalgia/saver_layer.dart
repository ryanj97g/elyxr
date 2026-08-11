// The screensaver, with the music player on top of it.
//
// The rain covers the whole tube — no hole cut in it. A rectangular window carved
// out of falling glyphs reads as a rendering fault, and it also meant the rain
// stopped behind the player instead of continuing behind it. So the player is
// drawn OVER the rain, as its content only: the title, the visualizer, the
// transport and the progress bar, with no panel, no border and no dimming. What
// isn't the player is the screensaver, and it keeps falling.
//
// Position comes from a LayerLink tied to the real deck (see DeckSlot), not from
// arithmetic: a CompositedTransformFollower tracks its target's box every frame, so
// the copy lands exactly on the real one with no coordinate conversion to get
// wrong and no chance of being a frame behind. The copy is the same widget with
// parts of itself not painted, so the controls can't sit anywhere other than where
// they normally do.
//
// The wheel works anywhere over the rain, so volume is adjustable without waking
// the tube. Scrolling never dismissed the saver (HomeScreen only wakes on a
// pointer DOWN) — this just gives the scroll somewhere to land.

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';
import '../../state/music.dart';
import '../deck_slot.dart';
import 'matrix_rain.dart';
import 'music_player.dart';

class SaverLayer extends StatelessWidget {
  final Palette palette;
  final DeckSlotRect deckRect;

  /// A tap on the rain dismisses it. Absorbed here so the same click doesn't also
  /// land on a file underneath. Taps on the player are exempt — see HomeScreen,
  /// which skips waking for a pointer down inside the deck's rect.
  final VoidCallback onWake;

  /// Turn the wheel while the saver is up. Fed from here rather than from the deck
  /// so it works over the whole screen.
  final ValueChanged<double> onVolume;

  /// The player drawn over the rain. Defaults to the real deck in saver form;
  /// overridden only by tests, so that where this lands can be checked without
  /// standing up the whole controller graph behind a real player.
  final WidgetBuilder? deckBuilder;

  final WidgetBuilder? titleBuilder;

  /// The text scale the real deck renders at (the density setting).
  ///
  /// Passed in rather than read here, because getting it wrong is invisible until
  /// it isn't: HomeScreen applies that scale to the tube's CONTENT, and the saver
  /// is the tube's overlay — outside it. The copy was drawing at 1.0 against a box
  /// measured from a scaled original, which made it taller than its box and threw
  /// an overflow banner across the screen.
  final double textScale;

  const SaverLayer({
    super.key,
    required this.palette,
    required this.deckRect,
    required this.onWake,
    required this.onVolume,
    this.deckBuilder,
    this.titleBuilder,
    this.textScale = 1.0,
  });

  /// Draw [child] at the deck's own text scale. Not applied to the rain, which has
  /// never been scaled and shouldn't start.
  Widget _atDeckScale(BuildContext context, Widget child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            // opaque, so a scroll over the rain's empty space counts too — it's
            // mostly gaps, and deferToChild would only catch a scroll landing
            // directly on a painted glyph.
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (sig) {
              if (sig is PointerScrollEvent) {
                onVolume(sig.scrollDelta.dy < 0 ? 0.05 : -0.05);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onWake,
              child: MatrixRain(palette: palette),
            ),
          ),
        ),
        ValueListenableBuilder<Rect?>(
          valueListenable: deckRect,
          builder: (context, rect, _) {
            if (rect == null) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: deckRect.link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: Offset(0, kDeckPadding.top),
                child: SizedBox(
                  width: rect.width,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _atDeckScale(
                        context,
                        titleBuilder?.call(context) ??
                            _SaverTitle(palette: palette)),
                  ),
                ),
              ),
            );
          },
        ),
        // The player, over the rain, at the real deck's box.
        ValueListenableBuilder<Rect?>(
          valueListenable: deckRect,
          builder: (context, rect, _) {
            if (rect == null) return const SizedBox.shrink();
            return Positioned(
              // The follower supplies the position; this only has to be somewhere
              // legal in the Stack for it to attach.
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: deckRect.link,
                showWhenUnlinked: false,
                // Width is pinned to the deck's, height is NOT. Forcing the
                // height meant any difference of a pixel or two between the copy
                // and the original showed up as an overflow banner across the
                // screen; letting it take its natural height means the worst case
                // is the controls sitting a pixel off, which nobody can see.
                child: SizedBox(
                  width: rect.width,
                  // The same padding the real deck sits in, from the same constant,
                  // so the inner geometry matches rather than approximating it.
                  child: Padding(
                    padding: kDeckPadding,
                    child: _atDeckScale(
                      context,
                      deckBuilder?.call(context) ??
                          MusicPlayerPanel(palette: palette, saver: true),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

///
/// `title` has already had the extension stripped and its underscores and hyphens
/// turned into spaces (MusicController._pretty), which is also what gives a name
/// like REPT_-_Magix_Samplitude_Pro_X somewhere sensible to break — the wrapping is
/// on words because the words exist by the time it gets here.
class _SaverTitle extends StatelessWidget {
  final Palette palette;
  const _SaverTitle({required this.palette});

  @override
  Widget build(BuildContext context) {
    final title = context.select<MusicController, String>((m) => m.title);
    return Text(
      title,
      textAlign: TextAlign.center,
      style: glass(22, palette.hot, height: 1.15),
    );
  }
}
