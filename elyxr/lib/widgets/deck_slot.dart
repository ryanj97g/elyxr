// Where the music deck is, so the screensaver can leave a hole for it.
//
// The saver is Tube's overlay, which covers the whole tube — and the deck lives
// inside the tube's content, so it cannot simply be raised above it. Rather than
// draw a second deck over the top (two visualizer tickers reading one controller,
// for one visible widget), the deck reports where it is and the saver clips itself
// around that rectangle. One deck, in its normal place in the layout, showing
// through the saver.
//
// The rect is in global coordinates, converted by whoever clips with it, because
// the reporter has no idea what space the consumer wants.

import 'package:flutter/material.dart';

/// The deck's rect, published by [DeckSlot] and read by the screensaver. Null
/// until the deck has been laid out, or while nothing is showing one — the saver
/// treats that as "no hole", so a missing rect can only ever mean the saver covers
/// everything, never that it clips something wrong.
class DeckSlotRect extends ValueNotifier<Rect?> {
  DeckSlotRect() : super(null);

  /// Ties the screensaver's copy of the deck to the real one's box. Position comes
  /// from here rather than from arithmetic on [value]: a LayerLink follows the
  /// target every frame and needs no coordinate conversion, so the copy cannot end
  /// up a few pixels out or a frame behind. [value] is only used for its SIZE and
  /// for deciding where a tap counts as "on the deck".
  final LayerLink link = LayerLink();
}

/// The padding around the deck inside its slot. Shared, so the screensaver's copy
/// sits on exactly the same inner geometry as the real one instead of a hand-copied
/// guess at it.
const EdgeInsets kDeckPadding = EdgeInsets.fromLTRB(13, 8, 13, 8);

/// Wraps the deck and keeps [notifier] up to date with its position.
///
/// Reported after every layout, not once: the deck changes height when it goes
/// from the idle one-line bar to the full player, and a hole cut to the old size
/// would clip the wrong region.
class DeckSlot extends StatefulWidget {
  final DeckSlotRect notifier;
  final Widget child;

  /// Whether this deck is worth an exception at all.
  ///
  /// False for the minimized bar, and the saver then covers it like everything
  /// else. An empty or folded player has nothing to show through a screensaver —
  /// carving a hole for it only draws the eye to a strip that reads as nothing,
  /// or worse, names a track that isn't playing.
  final bool reporting;

  const DeckSlot({
    super.key,
    required this.notifier,
    required this.child,
    this.reporting = true,
  });

  @override
  State<DeckSlot> createState() => _DeckSlotState();
}

class _DeckSlotState extends State<DeckSlot> {
  @override
  void dispose() {
    // Stop claiming a hole for a deck that is no longer on screen.
    widget.notifier.value = null;
    super.dispose();
  }

  void _report() {
    if (!mounted) return;
    if (!widget.reporting) {
      widget.notifier.value = null;
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (widget.notifier.value != rect) widget.notifier.value = rect;
  }

  @override
  Widget build(BuildContext context) {
    // After this frame's layout, so the box has a size and a position to read.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return CompositedTransformTarget(link: widget.notifier.link, child: widget.child);
  }
}
