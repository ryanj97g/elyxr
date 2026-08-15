// Library views: the same folder, read by what the files say about themselves
// instead of by what the filesystem calls them. Nothing here moves, renames, or
// creates anything — a view is a grouping of the entries the browser already
// holds, so the folders on disk stay exactly as they are and still gate what a
// view covers: whatever folder you are in is the library you are looking at.
//
// Grouping needs every entry, not just the pages scrolled into view, so
// switching into a view asks the browser to finish loading the folder first.

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../state/browse.dart';
import 'music.dart' show isAudioName;

/// FILES is the ordinary folder listing, untouched by any of this. The other
/// three are readings of the same entries.
enum LibraryView { files, songs, albums, artists }

extension LibraryViewLabel on LibraryView {
  String get label => switch (this) {
        LibraryView.files => 'FILES',
        LibraryView.songs => 'SONGS',
        LibraryView.albums => 'ALBUMS',
        LibraryView.artists => 'ARTISTS',
      };

  bool get isLibrary => this != LibraryView.files;
}

enum SongSort { title, artist, album, added, duration }

extension SongSortLabel on SongSort {
  String get label => switch (this) {
        SongSort.title => 'TITLE',
        SongSort.artist => 'ARTIST',
        SongSort.album => 'ALBUM',
        SongSort.added => 'ADDED',
        SongSort.duration => 'LENGTH',
      };
}

enum AlbumSort { name, artist, year }

extension AlbumSortLabel on AlbumSort {
  String get label => switch (this) {
        AlbumSort.name => 'ALBUM',
        AlbumSort.artist => 'ARTIST',
        AlbumSort.year => 'YEAR',
      };
}

/// What a track with no artist or album tag is filed under. Shown as written;
/// they sort to the end of every list rather than under "U".
const kNoArtist = 'UNKNOWN ARTIST';
const kNoAlbum = 'UNKNOWN ALBUM';

/// One album's tracks. [artist] is the album's dominant artist — the one most of
/// its tracks name — so a record with a guest on two songs is still filed under
/// whoever made it.
class AlbumGroup {
  final String name;
  final String artist;
  final int? year;
  final List<Entry> tracks;

  const AlbumGroup({
    required this.name,
    required this.artist,
    required this.year,
    required this.tracks,
  });

  bool get untitled => name == kNoAlbum;

  /// Total playing time, or null when not one track carried a length.
  int? get totalSeconds {
    var sum = 0;
    var any = false;
    for (final t in tracks) {
      final d = t.durationS;
      if (d != null) {
        sum += d;
        any = true;
      }
    }
    return any ? sum : null;
  }
}

/// One artist and their albums, already ordered.
class ArtistGroup {
  final String name;
  final List<AlbumGroup> albums;

  const ArtistGroup({required this.name, required this.albums});

  bool get unknown => name == kNoArtist;
  int get trackCount =>
      albums.fold(0, (n, a) => n + a.tracks.length);
}

/// Holds which view is showing, how it is ordered, what is being filtered, and
/// how far into artist → album you have drilled. Derived groupings are rebuilt
/// when the folder changes rather than on every frame, so scrolling a few
/// thousand tracks doesn't regroup them once per repaint.
class LibraryController extends ChangeNotifier {
  final BrowseController browse;

  LibraryController(this.browse) {
    browse.addListener(_onBrowseChanged);
  }

  LibraryView _view = LibraryView.files;
  SongSort _songSort = SongSort.title;
  AlbumSort _albumSort = AlbumSort.name;
  bool _desc = false;
  String _filter = '';

  // Where you are inside the artist/album drill. Both null = the top of the view.
  String? _artist;
  String? _album;

  // Derived, rebuilt on change rather than per frame.
  List<Entry>? _songs;
  List<AlbumGroup>? _albums;
  List<ArtistGroup>? _artists;

  // ---- getters ----
  LibraryView get view => _view;
  SongSort get songSort => _songSort;
  AlbumSort get albumSort => _albumSort;
  bool get desc => _desc;
  String get filter => _filter;
  String? get artistDrill => _artist;
  String? get albumDrill => _album;
  bool get isLibrary => _view.isLibrary;

  /// The label of whichever sort applies to the current view, for the chip.
  String get sortLabel => switch (_view) {
        LibraryView.albums => _albumSort.label,
        _ => _songSort.label,
      };

  /// The trail shown in place of the path crumbs while a view is open. Empty
  /// while at the top of a view.
  List<String> get trail => [
        if (_artist != null) _artist!,
        if (_album != null) _album!,
      ];

  // ---- switching ----

  /// Move to [v]. Entering a library view finishes loading the folder, because a
  /// grouping built from half the pages is a wrong answer rather than a partial
  /// one.
  Future<void> setView(LibraryView v) async {
    if (_view == v) return;
    _view = v;
    _artist = null;
    _album = null;
    _invalidate();
    notifyListeners();
    if (v.isLibrary) await browse.loadAll();
  }

  Future<void> cycleView() =>
      setView(LibraryView.values[(_view.index + 1) % LibraryView.values.length]);

  /// Cycle the sort that belongs to the view currently showing.
  void cycleSort() {
    if (_view == LibraryView.albums) {
      _albumSort =
          AlbumSort.values[(_albumSort.index + 1) % AlbumSort.values.length];
    } else {
      _songSort =
          SongSort.values[(_songSort.index + 1) % SongSort.values.length];
    }
    _invalidate();
    notifyListeners();
  }

  /// The label the one chip shows: the folder's sort while the folder is what
  /// you're looking at, otherwise the name of the view.
  String labelFor(SortKey folderSort) =>
      _view == LibraryView.files ? folderSort.label : _view.label;

  /// Every way of arranging this folder, on ONE control. The chip was already
  /// the app's "how is this list ordered" question; the views are more answers to
  /// it, not a second question, so they continue the same cycle rather than
  /// growing a second chip beside it.
  ///
  /// NAME → SIZE → DATE → ARTIST → ALBUM → SONGS → ALBUMS → ARTISTS → NAME.
  Future<void> cycleArrangement(BrowseController browse) async {
    switch (_view) {
      case LibraryView.files:
        // Past the last folder sort, the views take over.
        if (browse.sort == SortKey.album) {
          await setView(LibraryView.songs);
        } else {
          await browse.cycleSort();
        }
      case LibraryView.songs:
        await setView(LibraryView.albums);
      case LibraryView.albums:
        await setView(LibraryView.artists);
      case LibraryView.artists:
        await setView(LibraryView.files);
        await browse.setSort(SortKey.name);
    }
  }

  void toggleOrder() {
    _desc = !_desc;
    _invalidate();
    notifyListeners();
  }

  void setFilter(String q) {
    if (_filter == q) return;
    _filter = q;
    _invalidate();
    notifyListeners();
  }

  // ---- drilling ----

  void openArtist(String name) {
    _artist = name;
    _album = null;
    notifyListeners();
  }

  void openAlbum(String name) {
    _album = name;
    notifyListeners();
  }

  /// Step back one level of the drill. Returns false when already at the top,
  /// so the caller can fall through to whatever Back means outside the view.
  bool goBack() {
    if (_album != null) {
      _album = null;
      notifyListeners();
      return true;
    }
    if (_artist != null) {
      _artist = null;
      notifyListeners();
      return true;
    }
    return false;
  }

  void resetDrill() {
    if (_artist == null && _album == null) return;
    _artist = null;
    _album = null;
    notifyListeners();
  }

  // ---- derived views ----

  List<Entry> get songs => _songs ??= _buildSongs();
  List<AlbumGroup> get albums => _albums ??= _buildAlbums();
  List<ArtistGroup> get artists => _artists ??= _buildArtists();

  /// The tracks showing right now, whichever view and drill depth is open. This
  /// is what the player is handed, so what you hear matches what you can see.
  List<Entry> get visibleTracks {
    switch (_view) {
      case LibraryView.files:
        return const [];
      case LibraryView.songs:
        return songs;
      case LibraryView.albums:
        final a = _album;
        if (a == null) return const [];
        return albums
            .where((g) => g.name == a)
            .expand((g) => g.tracks)
            .toList();
      case LibraryView.artists:
        final ar = _artist;
        if (ar == null) return const [];
        final group = artists.where((g) => g.name == ar);
        if (group.isEmpty) return const [];
        final al = _album;
        return group
            .first
            .albums
            .where((g) => al == null || g.name == al)
            .expand((g) => g.tracks)
            .toList();
    }
  }

  /// The trove-relative path of an entry in the folder being viewed.
  String pathOf(Entry e) =>
      browse.path.isEmpty ? e.name : '${browse.path}/${e.name}';

  // ---- building ----

  void _onBrowseChanged() {
    _invalidate();
    // The folder's own listeners already rebuild; this only drops the cache so
    // the next read regroups against the new entries.
  }

  void _invalidate() {
    _songs = null;
    _albums = null;
    _artists = null;
  }

  /// Every audio file in the folder, filtered and ordered. Non-audio and folders
  /// are simply not part of a library view.
  List<Entry> _buildSongs() {
    final q = _filter.trim().toLowerCase();
    final out = <Entry>[];
    for (final e in browse.entries) {
      if (e.isDir || !isAudioName(e.name)) continue;
      if (q.isNotEmpty && !_matches(e, q)) continue;
      out.add(e);
    }
    out.sort(_compareSongs);
    return out;
  }

  /// A filter hits on any of the metadata, not just one field — the point is to
  /// type what you remember, whichever kind of thing that is.
  bool _matches(Entry e, String q) =>
      e.name.toLowerCase().contains(q) ||
      (e.title?.toLowerCase().contains(q) ?? false) ||
      (e.artist?.toLowerCase().contains(q) ?? false) ||
      (e.album?.toLowerCase().contains(q) ?? false);

  int _compareSongs(Entry a, Entry b) {
    final primary = switch (_songSort) {
      SongSort.title => _text(a.title ?? a.name, b.title ?? b.name),
      SongSort.artist => _tag(a.artist, b.artist),
      SongSort.album => _tag(a.album, b.album),
      SongSort.added => a.mtime.compareTo(b.mtime),
      SongSort.duration => _num(a.durationS, b.durationS),
    };
    final ordered = _desc ? -primary : primary;
    // Same stable tiebreak lymnal uses, so equal keys never shuffle between
    // rebuilds.
    return ordered != 0 ? ordered : _text(a.name, b.name);
  }

  List<AlbumGroup> _buildAlbums() {
    final byAlbum = <String, List<Entry>>{};
    final q = _filter.trim().toLowerCase();
    for (final e in browse.entries) {
      if (e.isDir || !isAudioName(e.name)) continue;
      if (q.isNotEmpty && !_matches(e, q)) continue;
      byAlbum.putIfAbsent(e.album ?? kNoAlbum, () => []).add(e);
    }
    final out = [
      for (final entry in byAlbum.entries) _albumOf(entry.key, entry.value)
    ];
    out.sort(_compareAlbums);
    return out;
  }

  /// Build one album from its tracks, picking the artist most of them name and
  /// the earliest year any of them carries.
  AlbumGroup _albumOf(String name, List<Entry> tracks) {
    final counts = <String, int>{};
    int? year;
    for (final t in tracks) {
      final a = t.artist;
      if (a != null) counts[a] = (counts[a] ?? 0) + 1;
      final y = t.year;
      if (y != null && (year == null || y < year)) year = y;
    }
    var artist = kNoArtist;
    var best = 0;
    for (final c in counts.entries) {
      if (c.value > best) {
        best = c.value;
        artist = c.key;
      }
    }
    tracks.sort(_compareSongs);
    return AlbumGroup(
        name: name, artist: artist, year: year, tracks: tracks);
  }

  int _compareAlbums(AlbumGroup a, AlbumGroup b) {
    // An untitled group is a bucket, not a record, so it sits at the end however
    // the rest is ordered rather than riding the reversal to the top.
    if (a.untitled != b.untitled) return a.untitled ? 1 : -1;
    final primary = switch (_albumSort) {
      AlbumSort.name => _text(a.name, b.name),
      AlbumSort.artist => _text(a.artist, b.artist),
      AlbumSort.year => _num(a.year, b.year),
    };
    final ordered = _desc ? -primary : primary;
    return ordered != 0 ? ordered : _text(a.name, b.name);
  }

  List<ArtistGroup> _buildArtists() {
    final byArtist = <String, List<Entry>>{};
    final q = _filter.trim().toLowerCase();
    for (final e in browse.entries) {
      if (e.isDir || !isAudioName(e.name)) continue;
      if (q.isNotEmpty && !_matches(e, q)) continue;
      byArtist.putIfAbsent(e.artist ?? kNoArtist, () => []).add(e);
    }
    final out = <ArtistGroup>[];
    for (final entry in byArtist.entries) {
      final byAlbum = <String, List<Entry>>{};
      for (final t in entry.value) {
        byAlbum.putIfAbsent(t.album ?? kNoAlbum, () => []).add(t);
      }
      final albums = [
        for (final a in byAlbum.entries) _albumOf(a.key, a.value)
      ]..sort(_compareAlbums);
      out.add(ArtistGroup(name: entry.key, albums: albums));
    }
    out.sort((a, b) {
      if (a.unknown != b.unknown) return a.unknown ? 1 : -1;
      final primary = _text(a.name, b.name);
      return _desc ? -primary : primary;
    });
    return out;
  }

  // Present-before-absent, then value — the same rule lymnal sorts tags by, so
  // an ordering reads the same in a view as it does in the file list.
  static int _tag(String? a, String? b) {
    if ((a == null) != (b == null)) return a == null ? 1 : -1;
    return _text(a ?? '', b ?? '');
  }

  static int _num(int? a, int? b) {
    if ((a == null) != (b == null)) return a == null ? 1 : -1;
    return (a ?? 0).compareTo(b ?? 0);
  }

  static int _text(String a, String b) {
    final folded = a.toLowerCase().compareTo(b.toLowerCase());
    return folded != 0 ? folded : a.compareTo(b);
  }

  @override
  void dispose() {
    browse.removeListener(_onBrowseChanged);
    super.dispose();
  }
}
