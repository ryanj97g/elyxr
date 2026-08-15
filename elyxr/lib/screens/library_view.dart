// The library views: the same folder read as songs, albums, or artists. These
// widgets assume the folder is loaded and ready — the loading, empty, gone, and
// offline states stay where they already were, wrapped around this by the files
// screen, so a view never grows its own copy of them.
//
// Nothing here writes: no move, no rename, no new folder. A view only decides
// what to show and in what order, and hands the player whatever is on screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../design/text.dart';
import '../design/tokens.dart';
import '../state/library.dart';
import '../state/music.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/tactile.dart';

/// Start [tracks] in the deck at [index]. The queue is exactly what the view is
/// showing, so what plays next is what reads next on screen.
void playFrom(BuildContext context, LibraryController lib, List<Entry> tracks,
    int index) {
  final client = context.read<SessionController>().client;
  if (client == null) return;
  final music = context.read<MusicController>();
  final queue = <TroveTrack>[
    for (final e in tracks)
      (
        path: lib.pathOf(e),
        name: e.name,
        title: e.title,
        artist: e.artist,
      ),
  ];
  if (queue.isEmpty) return;
  music.playTroveQueue(client, queue, index.clamp(0, queue.length - 1));
}

/// Routes to whichever view is open, at whatever drill depth. Returns null for
/// FILES so the caller keeps its ordinary list or grid.
Widget? libraryBody(BuildContext context, Palette p) {
  final lib = context.watch<LibraryController>();
  switch (lib.view) {
    case LibraryView.files:
      return null;
    case LibraryView.songs:
      return _Songs(palette: p);
    case LibraryView.albums:
      return lib.albumDrill == null
          ? _Albums(palette: p)
          : _AlbumTracks(palette: p);
    case LibraryView.artists:
      if (lib.artistDrill == null) return _Artists(palette: p);
      return lib.albumDrill == null
          ? _ArtistAlbums(palette: p)
          : _AlbumTracks(palette: p);
  }
}

/// The empty state a *view* has, which is not the same as an empty folder: the
/// folder may be full of things that simply aren't music.
Widget _nothing(Palette p, String line) =>
    Center(child: Text(line, style: glass(16, p.mid)));

Widget _footer(Palette p, String line) => Padding(
      padding: const EdgeInsets.all(6),
      child: Text('──── $line ────', style: glass(14, p.foot, spacing: 0.06)),
    );

// ----------------------------------------------------------------- songs ---

class _Songs extends StatelessWidget {
  final Palette palette;
  const _Songs({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.watch<LibraryController>();
    final songs = lib.songs;
    if (songs.isEmpty) {
      return _nothing(p, lib.filter.isEmpty
          ? 'NO MUSIC IN THIS FOLDER'
          : 'NOTHING MATCHES THAT');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
      itemCount: songs.length + 1,
      itemBuilder: (context, i) {
        if (i == songs.length) {
          return _footer(p, fmtCount(songs.length, 'TRACK').toUpperCase());
        }
        return _TrackRow(
          palette: p,
          entry: songs[i],
          index: i,
          tracks: songs,
          showArtist: true,
        );
      },
    );
  }
}

/// One track. The title carries the row; the artist rides underneath it, which
/// is the pair you actually scan for. Length sits right, aligned in its own
/// column so the ragged ends of titles never push it around.
class _TrackRow extends StatelessWidget {
  final Palette palette;
  final Entry entry;
  final int index;
  final List<Entry> tracks;
  final bool showArtist;
  final int? ordinal;

  const _TrackRow({
    required this.palette,
    required this.entry,
    required this.index,
    required this.tracks,
    this.showArtist = false,
    this.ordinal,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.read<LibraryController>();
    final band = index.isOdd ? p.aAlpha(0.043) : null;
    // A file with no title tag falls back to its filename, which is the only
    // name it has ever had.
    final title = entry.title ?? entry.name;
    final artist = entry.artist;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => playFrom(context, lib, tracks, index),
      child: Tactile(
        accent: p.a,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          decoration: BoxDecoration(color: band),
          child: Row(
            children: [
              if (ordinal != null)
                SizedBox(
                  width: 22,
                  child: Text('$ordinal',
                      textAlign: TextAlign.right,
                      style: glass(13, p.foot)),
                ),
              if (ordinal != null) const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: glass(15, p.bright)),
                    if (showArtist)
                      Text(artist ?? kNoArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: glass(12, p.foot)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(fmtDuration(entry.durationS), style: glass(13, p.mid)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- albums ---

class _Albums extends StatelessWidget {
  final Palette palette;
  const _Albums({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.watch<LibraryController>();
    final albums = lib.albums;
    if (albums.isEmpty) {
      return _nothing(p, lib.filter.isEmpty
          ? 'NO MUSIC IN THIS FOLDER'
          : 'NOTHING MATCHES THAT');
    }
    // Wider than the file tiles: an album tile carries two lines of text under
    // the block, and at the file grid's 76px they were unreadable.
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
      ),
      itemCount: albums.length,
      itemBuilder: (context, i) => _AlbumTile(palette: p, album: albums[i]),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  final Palette palette;
  final AlbumGroup album;
  const _AlbumTile({required this.palette, required this.album});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.read<LibraryController>();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => lib.openAlbum(album.name),
      child: Tactile(
        accent: p.a,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
          decoration: BoxDecoration(
            border: Border.all(color: p.aAlpha(0.2)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // No cover art anywhere in this app — reading the picture out of
              // every file is the one genuinely expensive part of a tag, and the
              // terminal doesn't show photographs. The block stands in for it.
              Expanded(
                child: Center(
                  child: Text('▓',
                      style: glass(34, p.aAlpha(0.55))),
                ),
              ),
              Text(album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass(13, p.bright)),
              Text(album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: glass(11, p.foot)),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text('${album.tracks.length}', style: glass(9, p.foot)),
                  const Spacer(),
                  if (album.year != null)
                    Text('${album.year}', style: glass(9, p.foot)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One album's tracks, numbered. Reached from the album grid or from inside an
/// artist; either way the drill state says which album, so this reads it back
/// off the controller rather than being handed one.
class _AlbumTracks extends StatelessWidget {
  final Palette palette;
  const _AlbumTracks({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.watch<LibraryController>();
    final tracks = lib.visibleTracks;
    if (tracks.isEmpty) return _nothing(p, 'THIS ALBUM IS EMPTY');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
      itemCount: tracks.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) return _AlbumHeader(palette: p, tracks: tracks);
        if (i == tracks.length + 1) {
          return _footer(p, fmtCount(tracks.length, 'TRACK').toUpperCase());
        }
        final index = i - 1;
        return _TrackRow(
          palette: p,
          entry: tracks[index],
          index: index,
          tracks: tracks,
          ordinal: index + 1,
        );
      },
    );
  }
}

class _AlbumHeader extends StatelessWidget {
  final Palette palette;
  final List<Entry> tracks;
  const _AlbumHeader({required this.palette, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.read<LibraryController>();
    var total = 0;
    for (final t in tracks) {
      total += t.durationS ?? 0;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: p.dim))),
      child: Row(
        children: [
          Expanded(
            child: Text(
              total > 0 ? fmtDuration(total) : '',
              style: chassis(9.5, p.foot, spacing: 0.12),
            ),
          ),
          hitTarget(
            pad: 4,
            onTap: () => playFrom(context, lib, tracks, 0),
            child: Text('▶ PLAY ALL', style: chassis(11, p.a, spacing: 0.1)),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- artists ---

class _Artists extends StatelessWidget {
  final Palette palette;
  const _Artists({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.watch<LibraryController>();
    final artists = lib.artists;
    if (artists.isEmpty) {
      return _nothing(p, lib.filter.isEmpty
          ? 'NO MUSIC IN THIS FOLDER'
          : 'NOTHING MATCHES THAT');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
      itemCount: artists.length + 1,
      itemBuilder: (context, i) {
        if (i == artists.length) {
          return _footer(p, fmtCount(artists.length, 'ARTIST').toUpperCase());
        }
        final a = artists[i];
        return _GroupRow(
          palette: p,
          index: i,
          title: a.name,
          sub: '${fmtCount(a.albums.length, 'ALBUM')} · '
              '${fmtCount(a.trackCount, 'TRACK')}',
          onTap: () => lib.openArtist(a.name),
        );
      },
    );
  }
}

/// One artist's albums, with their tracks a tap further in.
class _ArtistAlbums extends StatelessWidget {
  final Palette palette;
  const _ArtistAlbums({required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final lib = context.watch<LibraryController>();
    final name = lib.artistDrill;
    final match = lib.artists.where((g) => g.name == name);
    if (match.isEmpty) return _nothing(p, 'NOTHING UNDER THAT ARTIST');
    final albums = match.first.albums;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
      itemCount: albums.length + 1,
      itemBuilder: (context, i) {
        if (i == albums.length) {
          return _footer(p, fmtCount(albums.length, 'ALBUM').toUpperCase());
        }
        final a = albums[i];
        return _GroupRow(
          palette: p,
          index: i,
          title: a.name,
          sub: [
            if (a.year != null) '${a.year}',
            fmtCount(a.tracks.length, 'TRACK'),
          ].join(' · '),
          onTap: () => lib.openAlbum(a.name),
        );
      },
    );
  }
}

/// A row that opens a group rather than playing anything: artist, or album
/// inside an artist. The ▸ says it goes somewhere.
class _GroupRow extends StatelessWidget {
  final Palette palette;
  final int index;
  final String title;
  final String sub;
  final VoidCallback onTap;

  const _GroupRow({
    required this.palette,
    required this.index,
    required this.title,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Tactile(
        accent: p.a,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
              color: index.isOdd ? p.aAlpha(0.043) : null),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: glass(16, p.bright)),
                    Text(sub.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: glass(11, p.foot)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('▸', style: glass(15, p.mid)),
            ],
          ),
        ),
      ),
    );
  }
}
