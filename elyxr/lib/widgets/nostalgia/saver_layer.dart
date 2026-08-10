// The screensaver, with the music deck left showing through it.
//
// Covers everything the saver always covered, minus the deck's rectangle (see
// DeckSlot): the deck is the one thing you might still want to read and reach
// while the tube is asleep. It isn't lifted above the saver — it stays exactly
// where it is in the layout and the saver clips itself around it.
//
// The wheel works anywhere over this layer, not just over the deck, so the volume
// is adjustable without waking the tube. Scrolling never dismissed the saver
// (HomeScreen only wakes on a pointer DOWN), so that behaviour needed no change —
// only somewhere to catch the scroll.

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../design/tokens.dart';
import '../deck_slot.dart';
import 'matrix_rain.dart';

class SaverLayer extends StatelessWidget {
  final Palette palette;
  final DeckSlotRect deckRect;

  /// A tap anywhere on the saver dismisses it. Absorbed here so the same click
  /// doesn't also land on a file underneath.
  final VoidCallback onWake;

  /// Turn the wheel while the saver is up. Fed from here rather than from the deck
  /// so it works over the whole screen.
  final ValueChanged<double> onVolume;

  const SaverLayer({
    super.key,
    required this.palette,
    required this.deckRect,
    required this.onWake,
    required this.onVolume,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Rect?>(
      valueListenable: deckRect,
      builder: (context, rect, _) {
        // _Punched is OUTERMOST deliberately. The tap and wheel handlers below it
        // are opaque, so if they sat on top they would swallow everything aimed at
        // the deck regardless of any clipping — clipping changes what's painted,
        // not what's hit. With the clip outside them, the hole isn't hit-testable
        // at all, so a tap or a scroll over the deck falls straight through to the
        // real deck underneath and the saver never sees it.
        return _Punched(
          hole: rect,
          child: Listener(
            // opaque, so a scroll over the saver's empty space counts too — the
            // matrix is mostly gaps, and deferToChild would only catch a scroll
            // directly over a painted glyph.
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
        );
      },
    );
  }
}

/// Clips [child] to everything except [hole] — a global rect, converted here into
/// this widget's own space. A null hole clips nothing, so the saver falls back to
/// covering the lot rather than to clipping somewhere wrong.
class _Punched extends SingleChildRenderObjectWidget {
  final Rect? hole;
  const _Punched({required this.hole, required Widget child})
      : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPunched(hole: hole);

  @override
  void updateRenderObject(BuildContext context, _RenderPunched renderObject) {
    renderObject.hole = hole;
  }
}

class _RenderPunched extends RenderProxyBox {
  _RenderPunched({Rect? hole}) : _hole = hole;

  Rect? get hole => _hole;
  Rect? _hole;
  set hole(Rect? v) {
    if (_hole == v) return;
    _hole = v;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final h = _hole;
    if (h == null || child == null) {
      super.paint(context, offset);
      return;
    }
    // The reported rect is global; this render box knows its own transform, so it
    // can put the rect into local space itself. Nothing upstream has to care what
    // coordinate space anything is in.
    final local = globalToLocal(h.topLeft) & h.size;
    // Both the bounds and the path are in the child's own space — pushClipPath
    // applies [offset] itself, so adding it here would shift the hole twice.
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(local);
    context.pushClipPath(needsCompositing, offset, Offset.zero & size, path,
        (ctx, off) => super.paint(ctx, off));
  }

  // The hole is where the deck shows through, so it must not swallow clicks meant
  // for the deck — a tap in there falls past the saver to the player beneath.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final h = _hole;
    if (h != null) {
      final local = globalToLocal(h.topLeft) & h.size;
      if (local.contains(position)) return false;
    }
    return super.hitTest(result, position: position);
  }
}
