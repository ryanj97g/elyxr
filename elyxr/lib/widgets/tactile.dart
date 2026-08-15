// One interaction abstraction for "this is touchable," so a clickable surface
// lights the same phosphor glow on every device: a mouse *hovers* it on the
// desktop, a finger *presses* it on Android — both resolve to the same lit
// state. It never consumes the gesture (MouseRegion and Listener are passive),
// so the child keeps its own onTap/onLongPress handlers untouched.

import 'package:flutter/material.dart';

/// Wrap a label or glyph in a hit box a finger can actually land on. Most
/// controls in this app are bare text, and a GestureDetector around bare text
/// only catches the glyph — around 12px tall, well under the ~44px a touch
/// target needs. The padding is transparent, so the layout keeps its density and
/// only the tappable area grows. Horizontal padding doubles as the gap between
/// neighbours.
Widget hitTarget({required Widget child, VoidCallback? onTap, double pad = 11}) =>
    GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 7, vertical: pad),
        child: child,
      ),
    );

/// Wraps [child] and lights an accent glow when the pointer is over it (desktop
/// hover) or pressing it (touch). Passive — stack it around anything that
/// already handles taps.
class Tactile extends StatefulWidget {
  final Color accent;
  final BorderRadius? radius;
  final double intensity; // peak glow strength (glow alpha ≈ this)
  final Widget child;

  const Tactile({
    super.key,
    required this.accent,
    required this.child,
    this.radius,
    this.intensity = 0.14,
  });

  @override
  State<Tactile> createState() => _TactileState();
}

class _TactileState extends State<Tactile> {
  bool _hover = false; // pointer resting over it (desktop)
  bool _press = false; // pointer held down (touch, and desktop click)

  bool get _lit => _hover || _press;

  void _update(void Function() change) {
    final was = _lit;
    change();
    if (_lit != was) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Press reads brighter than a passing hover.
    final k = _press ? 1.0 : 0.62;
    final a = widget.accent;
    return MouseRegion(
      onEnter: (_) => _update(() => _hover = true),
      onExit: (_) => _update(() => _hover = false),
      child: Listener(
        onPointerDown: (_) => _update(() => _press = true),
        onPointerUp: (_) => _update(() => _press = false),
        onPointerCancel: (_) => _update(() => _press = false),
        // The lit state: a bright accent outline plus a gentle wash, drawn in
        // front of the surface within the widget's own bounds so a clipping
        // parent (the file ListView) can't swallow it. A phosphor box-shadow
        // glow is added behind, visible wherever nothing clips it.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: widget.radius,
            // A soft accent wash under the content...
            color: _lit ? a.withValues(alpha: 0.07 * k) : null,
            boxShadow: _lit
                ? [
                    // ...an INNER phosphor bloom feathered in from the edges. An
                    // outer shadow gets clipped away by the file list, which is
                    // why the hover used to read as a hard box; an inner glow is
                    // painted within the widget's own bounds, so it always shows —
                    // it's a real glow, not an outline.
                    BoxShadow(
                        color: a.withValues(alpha: 0.55 * k),
                        blurRadius: 15,
                        blurStyle: BlurStyle.inner),
                    // ...plus an outer halo wherever nothing clips it (the metal
                    // rails, the grid tiles).
                    BoxShadow(
                        color: a.withValues(alpha: 0.38 * k),
                        blurRadius: 20,
                        spreadRadius: -3),
                  ]
                : const [],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.radius,
            // Only a faint edge — soft, not a hard box. The glow carries the cue.
            border: _lit
                ? Border.all(color: a.withValues(alpha: 0.22 * k), width: 1)
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
