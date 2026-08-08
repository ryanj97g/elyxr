// Browsing one folder at a time (§03–§04). Sorting and paging are lymnal's
// job; this holds the current folder, the accumulated pages, the selection,
// navigation history, and the search overlay, and it distinguishes loading,
// empty, and no-longer-existing from a populated folder.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import 'session.dart';

enum FolderState { loading, ready, empty, gone, offline }

enum SortKey { name, size, mtime }

extension SortKeyWire on SortKey {
  String get wire => switch (this) {
        SortKey.name => 'name',
        SortKey.size => 'size',
        SortKey.mtime => 'mtime',
      };
  String get label => switch (this) {
        SortKey.name => 'NAME',
        SortKey.size => 'SIZE',
        SortKey.mtime => 'DATE',
      };
}

class _CachedFolder {
  final List<Entry> entries;
  final String? cursor;
  final DateTime at;
  _CachedFolder(this.entries, this.cursor, this.at);
}

class BrowseController extends ChangeNotifier {
  final SessionController session;
  BrowseController(this.session);

  String _path = '';
  final List<Entry> _entries = [];
  String? _cursor;
  bool _loadingMore = false;
  FolderState _state = FolderState.loading;
  ConnectionFault? _fault;

  SortKey _sort = SortKey.name;
  bool _desc = false;

  final Set<String> _sel = {};
  int? _anchorIndex; // for range selection

  int _usedBytes = 0;
  List<Warning> _warnings = [];

  // Search overlay.
  String _query = '';
  SearchResult? _search;
  bool _searching = false;

  // Navigation.
  final List<String> _back = [];
  final List<String> _forward = [];
  final Map<String, double> _scroll = {}; // remembered position per path
  String? _markedEntry; // the entry to highlight after choosing a search hit

  // 5-second listing cache.
  final Map<String, _CachedFolder> _cache = {};
  static const _cacheTtl = Duration(seconds: 5);

  // ---- getters ----
  String get path => _path;
  List<Entry> get entries => List.unmodifiable(_entries);
  FolderState get state => _state;
  ConnectionFault? get fault => _fault;
  SortKey get sort => _sort;
  bool get desc => _desc;
  bool get hasMore => _cursor != null;
  bool get loadingMore => _loadingMore;
  Set<String> get selection => Set.unmodifiable(_sel);
  bool get hasSelection => _sel.isNotEmpty;
  int get usedBytes => _usedBytes;
  int get maxBytes => session.health?.maxBytes ?? 0;
  List<Warning> get warnings => _warnings;
  String get query => _query;
  SearchResult? get searchResult => _search;
  bool get searching => _searching;
  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  bool get canGoUp => _path.isNotEmpty;
  String? get markedEntry => _markedEntry;

  /// The path split into its ancestor crumbs.
  List<String> get crumbs =>
      _path.isEmpty ? const [] : _path.split('/');

  double scrollOf(String path) => _scroll[path] ?? 0;
  void rememberScroll(double offset) => _scroll[_path] = offset;

  // ---- navigation ----

  /// Open a folder, remembering where you were so Back returns to it.
  Future<void> open(String path, {bool pushHistory = true}) async {
    if (pushHistory && path != _path) {
      _back.add(_path);
      _forward.clear();
    }
    _path = path;
    _markedEntry = null;
    await _load();
  }

  Future<void> goUp() async {
    if (!canGoUp) return;
    final i = _path.lastIndexOf('/');
    await open(i < 0 ? '' : _path.substring(0, i));
  }

  Future<void> goBack() async {
    if (_back.isEmpty) return;
    _forward.add(_path);
    _path = _back.removeLast();
    await _load();
  }

  Future<void> goForward() async {
    if (_forward.isEmpty) return;
    _back.add(_path);
    _path = _forward.removeLast();
    await _load();
  }

  /// Jump to an ancestor by crumb index (−1 = root).
  Future<void> goToCrumb(int index) async {
    final parts = crumbs;
    final target = index < 0 ? '' : parts.sublist(0, index + 1).join('/');
    await open(target);
  }

  // ---- sorting ----

  Future<void> setSort(SortKey key) async {
    if (_sort == key) return;
    _sort = key;
    _dropCacheForPath();
    await _load(); // changing the sort discards the page and asks again
  }

  Future<void> toggleOrder() async {
    _desc = !_desc;
    _dropCacheForPath();
    await _load();
  }

  /// Cycle NAME → SIZE → DATE, as the sort chip does.
  Future<void> cycleSort() async {
    const order = [SortKey.name, SortKey.size, SortKey.mtime];
    await setSort(order[(order.indexOf(_sort) + 1) % order.length]);
  }

  // ---- loading & paging ----

  Future<void> _load() async {
    _sel.clear();
    _anchorIndex = null;

    final client = session.client;
    if (client == null) {
      _entries.clear();
      _cursor = null;
      _state = FolderState.offline;
      _fault = ConnectionFault.unreachable;
      notifyListeners();
      return;
    }

    // Fresh cache within 5s → no request.
    final cached = _cache[_cacheKey];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      _entries
        ..clear()
        ..addAll(cached.entries);
      _cursor = cached.cursor;
      _state = _entries.isEmpty ? FolderState.empty : FolderState.ready;
      notifyListeners();
      return;
    }

    _state = FolderState.loading;
    notifyListeners();
    try {
      final reqPath = _path;
      final page = await client.list(
        path: reqPath,
        sort: _sort.wire,
        order: _desc ? 'desc' : 'asc',
      );
      // If we navigated elsewhere while this was in flight, a newer load owns
      // the list — drop this result.
      if (reqPath != _path) return;
      // Replace in one synchronous step (clear + fill, no await between) so two
      // refreshes racing can't leave duplicate rows.
      _entries
        ..clear()
        ..addAll(page.entries);
      _cursor = page.nextCursor;
      _usedBytes = page.usedBytes;
      _warnings = page.warnings;
      _cache[_cacheKey] = _CachedFolder(List.of(_entries), _cursor, DateTime.now());
      _state = _entries.isEmpty ? FolderState.empty : FolderState.ready;
      _fault = null;
    } on ConnectionError catch (e) {
      _state = FolderState.offline;
      _fault = e.fault;
      // Nudge the global link status so the whole app reflects it.
      unawaited(session.refresh());
      _scheduleRetry();
    } on LymnalError catch (e) {
      // A folder that no longer exists offers to go up (§03).
      _state = e.code == 'NOT_FOUND' ? FolderState.gone : FolderState.ready;
    }
    notifyListeners();
  }

  /// Fetch the next page as the end of the list is reached.
  Future<void> loadMore() async {
    if (_cursor == null || _loadingMore) return;
    final client = session.client;
    if (client == null) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await client.list(
        path: _path,
        sort: _sort.wire,
        order: _desc ? 'desc' : 'asc',
        cursor: _cursor,
      );
      _entries.addAll(page.entries);
      _cursor = page.nextCursor;
      _cache[_cacheKey] = _CachedFolder(List.of(_entries), _cursor, DateTime.now());
    } on ConnectionError catch (e) {
      _fault = e.fault;
    } on LymnalError {
      // Leave what we have; the footer just stops growing.
    }
    _loadingMore = false;
    notifyListeners();
  }

  /// Re-fetch the current folder, bypassing the cache (after an event, or a
  /// manual retry once the server answers again).
  Future<void> refreshFolder() async {
    _dropCacheForPath();
    await _load();
  }

  String get _cacheKey => '$_path|${_sort.wire}|${_desc ? 'd' : 'a'}';
  void _dropCacheForPath() {
    _cache.removeWhere((k, _) => k.startsWith('$_path|'));
  }

  // ---- selection ----

  /// A plain single click: make [index] the only selection (so the details box
  /// shows just this one file). Multi-select is the click-and-hold gesture.
  void selectOnly(int index) {
    _sel
      ..clear()
      ..add(_entries[index].name);
    _anchorIndex = index;
    notifyListeners();
  }

  void toggle(int index) {
    final name = _entries[index].name;
    if (_sel.contains(name)) {
      _sel.remove(name);
    } else {
      _sel.add(name);
      _anchorIndex = index;
    }
    notifyListeners();
  }

  /// Extend a contiguous range from the last anchor to [index].
  void selectRange(int index) {
    final anchor = _anchorIndex ?? index;
    final lo = anchor < index ? anchor : index;
    final hi = anchor < index ? index : anchor;
    for (var i = lo; i <= hi; i++) {
      _sel.add(_entries[i].name);
    }
    notifyListeners();
  }

  void selectAll() {
    _sel.addAll(_entries.map((e) => e.name));
    notifyListeners();
  }

  void clearSelection() {
    _sel.clear();
    _anchorIndex = null;
    notifyListeners();
    applyDeferredIfIdle();
  }

  /// The trove-relative paths of the current selection, for resolve/download/
  /// delete/move.
  List<String> get selectionPaths => _sel
      .map((name) => _path.isEmpty ? name : '$_path/$name')
      .toList();

  // ---- search ----

  Future<void> setQuery(String q) async {
    _query = q;
    if (q.trim().length < 2) {
      _search = null;
      notifyListeners();
      return;
    }
    final client = session.client;
    if (client == null) return;
    _searching = true;
    notifyListeners();
    try {
      _search = await client.search(q.trim(), path: _path);
    } on ConnectionError catch (e) {
      _fault = e.fault;
    } on LymnalError {
      _search = null;
    }
    _searching = false;
    notifyListeners();
  }

  void clearQuery() {
    _query = '';
    _search = null;
    notifyListeners();
  }

  /// Choosing a search hit navigates to its folder with that entry marked.
  Future<void> openHit(SearchHit hit) async {
    _query = '';
    _search = null;
    await open(hit.folder);
    _markedEntry = hit.name;
    notifyListeners();
  }

  // ---- changing things (§06) ----

  /// Rename an entry in the current folder. Throws [LymnalError] on a taken
  /// name so the UI can offer Replace / Keep both / Cancel.
  Future<void> rename(String name, String newName,
      {String onConflict = 'fail'}) async {
    final client = session.client;
    if (client == null) return;
    final from = _path.isEmpty ? name : '$_path/$name';
    final to = _path.isEmpty ? newName : '$_path/$newName';
    await client.move(from, to, onConflict: onConflict);
    await refreshFolder();
  }

  /// Move a set of paths into [destFolder].
  Future<void> moveInto(List<String> paths, String destFolder,
      {String onConflict = 'fail'}) async {
    final client = session.client;
    if (client == null) return;
    for (final p in paths) {
      final name = p.split('/').last;
      final to = destFolder.isEmpty ? name : '$destFolder/$name';
      await client.move(p, to, onConflict: onConflict);
    }
    clearSelection();
    await refreshFolder();
  }

  /// Delete a set of paths. Returns lymnal's per-path result so the UI can
  /// report what went, what did not, and why.
  Future<Map<String, dynamic>> deletePaths(List<String> paths) async {
    final client = session.client;
    if (client == null) return const {};
    final result = await client.delete(paths);
    clearSelection();
    await refreshFolder();
    return result;
  }

  /// Create a folder in the current directory, named in the same action.
  Future<void> newFolder(String name) async {
    final client = session.client;
    if (client == null) return;
    final path = _path.isEmpty ? name : '$_path/$name';
    await client.mkdir(path);
    await refreshFolder();
  }

  // ---- live updates from the event stream (§03) ----

  StreamSubscription? _events;
  bool _dirty = false;

  /// Subscribe to the change stream so a file added on the server appears
  /// without a refresh. Idempotent; reconnects if the stream drops.
  void connectEvents() {
    if (_events != null) return;
    final client = session.client;
    if (client == null) return;
    _events = client.events().listen(
      _onEvent,
      onError: (_) => _reconnectEvents(),
      onDone: _reconnectEvents,
      cancelOnError: true,
    );
  }

  void _reconnectEvents() {
    _events = null;
    // The stream dropping often means the server restarted — which is what an
    // update does. Re-check its build on the way back, so a client that missed
    // the live announcement (or was launched after it) still catches up.
    Future.delayed(const Duration(seconds: 2), () async {
      await session.refresh();
      if (session.status == LinkStatus.ok) connectEvents();
    });
  }

  void disconnectEvents() {
    _events?.cancel();
    _events = null;
  }

  void _onEvent(ServerEvent ev) {
    if (ev.isUpdate) {
      // The server is updating — signal the app so this device updates in step.
      session.signalPeerUpdate();
      return;
    }
    if (ev.isUsage) {
      _usedBytes = (ev.data['used_bytes'] as num?)?.toInt() ?? _usedBytes;
      final w = ev.data['warnings'] as List? ?? [];
      _warnings = w.map((e) => Warning.fromJson((e as Map).cast())).toList();
      notifyListeners();
      return;
    }
    if (!ev.isChange) return;
    final p = ev.changePath;
    if (p == null) return;
    // Only the folder we're looking at matters. Updates are deferred while a
    // selection is active, so nothing moves under a click (§03).
    final parent = p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';
    if (parent != _path) return;
    if (hasSelection || _query.isNotEmpty) {
      _dirty = true;
    } else {
      _scheduleRefresh();
    }
  }

  Timer? _refreshDebounce;

  /// One filesystem change fires several low-level events (create, then write),
  /// so a single add can arrive as a burst. Coalesce a burst into one refresh
  /// instead of firing several that race each other.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!hasSelection && _query.isEmpty) refreshFolder();
    });
  }

  /// Apply any deferred updates once the list is idle again.
  void applyDeferredIfIdle() {
    if (_dirty && !hasSelection && _query.isEmpty) {
      _dirty = false;
      refreshFolder();
    }
  }

  /// After a connection error, keep re-attempting the load so the list recovers
  /// on its own once the server is reachable again (e.g. after it restarts),
  /// instead of sitting on the offline notice until the person navigates.
  Timer? _retry;
  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 4), () {
      if (_state == FolderState.offline) _load();
    });
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _retry?.cancel();
    _events?.cancel();
    super.dispose();
  }
}
