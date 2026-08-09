// The video preview that fills the selection box when a single video file is
// picked — click a clip and it plays right there, the way clicking an audio file
// plays it. libmpv (via media_kit) streams the file straight from the local
// proxy, so it starts without waiting for the whole thing to download and can
// seek. Audio still runs on audioplayers; this is only for video.
//
// If the player can't come up (libmpv missing, a source that won't open), it
// quietly renders nothing rather than taking anything down with it.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../design/tokens.dart';

class VideoPreview extends StatefulWidget {
  final Palette palette;
  /// The proxy URL that serves the file's bytes (with Range support).
  final String url;
  /// Auth header for the source, when the client carries a token.
  final Map<String, String>? headers;
  const VideoPreview({
    super.key,
    required this.palette,
    required this.url,
    this.headers,
  });

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  Player? _player;
  VideoController? _controller;
  bool _failed = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final player = Player();
      final controller = VideoController(player);
      _player = player;
      _controller = controller;
      // Opens and autoplays. httpHeaders carries the bearer token when the
      // client has one (a direct-to-server session); the loopback proxy ignores
      // it, so it's harmless there.
      await player.open(Media(widget.url, httpHeaders: widget.headers));
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    // Disposing the player stops playback and frees libmpv for this clip.
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null) return const SizedBox.shrink();
    final p = widget.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        color: Colors.black,
        constraints: const BoxConstraints(maxHeight: 200),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: _ready
              ? Video(controller: c, fit: BoxFit.contain, controls: AdaptiveVideoControls)
              : Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: p.a),
                  ),
                ),
        ),
      ),
    );
  }
}
