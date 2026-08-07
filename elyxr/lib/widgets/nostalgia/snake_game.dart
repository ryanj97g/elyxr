// Snake — the hidden minigame, unlocked by tapping the ELYXR wordmark seven
// times in Nostalgia Mode. It plays on the phosphor tube in the accent colour.
// Steered by arrow keys / WASD on a desktop, or by swiping on touch. Tap EXIT
// (or press Esc) to leave; tap to restart after a game over.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/text.dart';
import '../../design/tokens.dart';

class SnakeGame extends StatefulWidget {
  final Palette palette;
  final VoidCallback onExit;
  const SnakeGame({super.key, required this.palette, required this.onExit});

  @override
  State<SnakeGame> createState() => _SnakeGameState();
}

class _SnakeGameState extends State<SnakeGame> {
  static const int _cols = 16;
  static const int _rows = 26;

  final _rnd = Random();
  final FocusNode _focus = FocusNode();

  late List<Point<int>> _snake;
  Point<int> _dir = const Point(1, 0);
  Point<int> _pending = const Point(1, 0);
  late Point<int> _food;
  int _score = 0;
  bool _over = false;
  Timer? _loop;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _snake = [const Point(8, 13), const Point(7, 13), const Point(6, 13)];
    _dir = const Point(1, 0);
    _pending = _dir;
    _score = 0;
    _over = false;
    _placeFood();
    _loop?.cancel();
    _loop = Timer.periodic(const Duration(milliseconds: 150), (_) => _tick());
    setState(() {});
  }

  void _placeFood() {
    Point<int> f;
    do {
      f = Point(_rnd.nextInt(_cols), _rnd.nextInt(_rows));
    } while (_snake.contains(f));
    _food = f;
  }

  void _tick() {
    if (_over) return;
    // Ignore a reversal into yourself.
    if (!(_pending.x == -_dir.x && _pending.y == -_dir.y)) _dir = _pending;
    final head = Point(_snake.first.x + _dir.x, _snake.first.y + _dir.y);
    final hitsWall =
        head.x < 0 || head.y < 0 || head.x >= _cols || head.y >= _rows;
    if (hitsWall || _snake.contains(head)) {
      setState(() => _over = true);
      _loop?.cancel();
      return;
    }
    _snake.insert(0, head);
    if (head == _food) {
      _score++;
      _placeFood();
    } else {
      _snake.removeLast();
    }
    setState(() {});
  }

  void _steer(int dx, int dy) => _pending = Point(dx, dy);

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      _steer(0, -1);
    } else if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyS) {
      _steer(0, 1);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      _steer(-1, 0);
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      _steer(1, 0);
    } else if (k == LogicalKeyboardKey.escape) {
      widget.onExit();
    }
  }

  void _onPan(DragUpdateDetails d) {
    if (d.delta.dx.abs() > d.delta.dy.abs()) {
      _steer(d.delta.dx > 0 ? 1 : -1, 0);
    } else if (d.delta.dy != 0) {
      _steer(0, d.delta.dy > 0 ? 1 : -1);
    }
  }

  @override
  void dispose() {
    _loop?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: _onPan,
        onTap: _over ? _reset : null,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SnakePainter(_snake, _food, _cols, _rows,
                    body: p.a, head: p.bright, foodColor: p.soft),
              ),
            ),
            // Score, top-left.
            Positioned(
              left: 10,
              top: 8,
              child: Text('SNAKE · $_score', style: glass(16, p.a)),
            ),
            // Exit, top-right.
            Positioned(
              right: 8,
              top: 6,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onExit,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text('EXIT ✕', style: glass(15, p.mid)),
                ),
              ),
            ),
            if (_over)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('GAME OVER',
                        style: glass(30, p.bright).copyWith(
                            shadows: [Shadow(color: p.a, blurRadius: 12)])),
                    const SizedBox(height: 6),
                    Text('score $_score', style: glass(18, p.mid)),
                    const SizedBox(height: 10),
                    Text('TAP TO RESTART', style: glass(15, p.a)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SnakePainter extends CustomPainter {
  final List<Point<int>> snake;
  final Point<int> food;
  final int cols, rows;
  final Color body, head, foodColor;

  _SnakePainter(this.snake, this.food, this.cols, this.rows,
      {required this.body, required this.head, required this.foodColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final cw = size.width / cols;
    final ch = size.height / rows;
    final gap = (cw < ch ? cw : ch) * 0.12;

    void cell(Point<int> c, Color color) {
      final r = Rect.fromLTWH(
          c.x * cw + gap, c.y * ch + gap, cw - gap * 2, ch - gap * 2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(2)),
          Paint()..color = color);
    }

    // Food, with a soft glow.
    canvas.drawCircle(
        Offset(food.x * cw + cw / 2, food.y * ch + ch / 2),
        (cw < ch ? cw : ch) * 0.32,
        Paint()
          ..color = foodColor
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));

    for (var i = 0; i < snake.length; i++) {
      cell(snake[i], i == 0 ? head : body.withValues(alpha: 0.9));
    }
  }

  @override
  bool shouldRepaint(covariant _SnakePainter old) => true;
}
