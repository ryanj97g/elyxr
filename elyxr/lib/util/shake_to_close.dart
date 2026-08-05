// Shake the window hard to close it. The OS still does the smooth dragging;
// this only watches the window's position a few times a second and, if it's
// being whipped back and forth (several direction reversals in quick
// succession), closes the app. The bar is deliberately high — several
// reversals within a short span — so an ordinary fast drag never triggers it.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

class ShakeToClose extends StatefulWidget {
  final Widget child;
  const ShakeToClose({super.key, required this.child});

  @override
  State<ShakeToClose> createState() => _ShakeToCloseState();
}

class _ShakeToCloseState extends State<ShakeToClose> {
  static const _poll = Duration(milliseconds: 55);
  static const _minMovePx = 16.0; // ignore small jitters
  static const _windowMs = 1400; // reversals must land within this span
  static const _reversalsToClose = 6; // ~3 full back-and-forth shakes

  Timer? _timer;
  bool _busy = false;
  Offset? _last;
  int _dir = 0;
  final List<int> _reversals = [];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_poll, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      _process(await windowManager.getPosition());
    } catch (_) {
      // getPosition can fail transiently; ignore.
    }
    _busy = false;
  }

  void _process(Offset pos) {
    final last = _last;
    _last = pos;
    if (last == null) return;
    final dx = pos.dx - last.dx;
    if (dx.abs() < _minMovePx) return; // no real horizontal motion
    final dir = dx > 0 ? 1 : -1;
    if (_dir != 0 && dir != _dir) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _reversals.add(now);
      _reversals.removeWhere((t) => now - t > _windowMs);
      if (_reversals.length >= _reversalsToClose) {
        _reversals.clear();
        windowManager.close();
        return;
      }
    }
    _dir = dir;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
