// The device's own settings, persisted with shared_preferences (DESIGN.md ·
// State). The bearer token is never here — it lives in the keyring (see
// session.dart). Everything in this file is about this machine only.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/tokens.dart';

/// Which mode elyxr runs in on this device (§01 of the elyxr spec).
enum AppMode { client, server }

/// The list view: the dense phosphor list, or 3-across tiles.
enum ViewMode { text, grid }

class SettingsController extends ChangeNotifier {
  final SharedPreferences _prefs;

  SettingsController(this._prefs) {
    _load();
  }

  // Persisted fields.
  Accent _accent = Accent.green;
  Density _density = Density.mid;
  bool _dark = true;
  ViewMode _mode = ViewMode.text;
  bool _trove = false; // is trove running (the folder switch)
  bool _notify = true;
  int _cache = 10; // 1..20 → 0.5–15 GB
  AppMode _appMode = AppMode.client;
  String _downloadDir = '~/Downloads';
  String _mountPath = '~/Desktop/trove'; // where the trove mounts — on the Desktop, like a plugged-in drive
  bool _confirmDelete = true; // show the "removes it for everyone" delete guard
  int _atOnce = 3;

  Accent get accent => _accent;
  Density get density => _density;
  bool get dark => _dark;
  ViewMode get mode => _mode;
  bool get trove => _trove;
  bool get notify => _notify;
  int get cache => _cache;
  AppMode get appMode => _appMode;
  String get downloadDir => _downloadDir;
  String get mountPath => _mountPath;
  bool get confirmDelete => _confirmDelete;
  int get atOnce => _atOnce;

  /// Cache slider position → gigabytes (0.5–15 GB across 20 steps).
  double get cacheGb => 0.5 + (_cache / 20) * 14.5;

  void _load() {
    _accent = _enumByName(Accent.values, _prefs.getString('accent'), Accent.green);
    _density =
        _enumByName(Density.values, _prefs.getString('density'), Density.mid);
    _dark = _prefs.getBool('dark') ?? true;
    _mode = _enumByName(ViewMode.values, _prefs.getString('mode'), ViewMode.text);
    _trove = _prefs.getBool('trove') ?? false;
    _notify = _prefs.getBool('notify') ?? true;
    _cache = _prefs.getInt('cache') ?? 10;
    _appMode =
        _enumByName(AppMode.values, _prefs.getString('appMode'), AppMode.client);
    _downloadDir = _prefs.getString('downloadDir') ?? '~/Downloads';
    _mountPath = _prefs.getString('mountPath') ?? '~/Desktop/trove';
    _confirmDelete = _prefs.getBool('confirmDelete') ?? true;
    _atOnce = _prefs.getInt('atOnce') ?? 3;
  }

  T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  // Setters persist and notify.
  set accent(Accent v) => _set('accent', () => _accent = v, () => _prefs.setString('accent', v.name));
  set density(Density v) => _set('density', () => _density = v, () => _prefs.setString('density', v.name));
  set dark(bool v) => _set('dark', () => _dark = v, () => _prefs.setBool('dark', v));
  set mode(ViewMode v) => _set('mode', () => _mode = v, () => _prefs.setString('mode', v.name));
  set trove(bool v) => _set('trove', () => _trove = v, () => _prefs.setBool('trove', v));
  set notify(bool v) => _set('notify', () => _notify = v, () => _prefs.setBool('notify', v));
  set cache(int v) => _set('cache', () => _cache = v.clamp(1, 20), () => _prefs.setInt('cache', _cache));
  set appMode(AppMode v) => _set('appMode', () => _appMode = v, () => _prefs.setString('appMode', v.name));
  set downloadDir(String v) => _set('downloadDir', () => _downloadDir = v, () => _prefs.setString('downloadDir', v));
  set mountPath(String v) => _set('mountPath', () => _mountPath = v, () => _prefs.setString('mountPath', v));
  set confirmDelete(bool v) => _set('confirmDelete', () => _confirmDelete = v, () => _prefs.setBool('confirmDelete', v));
  set atOnce(int v) => _set('atOnce', () => _atOnce = v, () => _prefs.setInt('atOnce', v));

  void _set(String _, VoidCallback apply, VoidCallback persist) {
    apply();
    persist();
    notifyListeners();
  }

  /// The palette for the current accent and tube setting.
  Palette get palette => Palette(_accent, _dark);
}
