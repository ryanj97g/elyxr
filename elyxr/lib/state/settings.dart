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
  bool _trove = false; // "Use System File Browser" — the optional gate mount, off by default
  AppMode _appMode = AppMode.client;
  String _downloadDir = '~/Downloads';
  String _mountPath = '~/Desktop/trove'; // where the trove mounts — a normal folder on the Desktop
  bool _confirmDelete = true; // show the "removes it for everyone" delete guard
  int _atOnce = 3;
  // The two accent drag axes: saturation for a colour phosphor (pushes chroma
  // AND glow), lightness for the mono/white phosphor.
  double _accentSat = 1.0; // 0.4–2.6
  double _monoL = 0.72; // 0.12–0.99

  Accent get accent => _accent;
  Density get density => _density;
  bool get dark => _dark;
  ViewMode get mode => _mode;
  bool get trove => _trove;
  AppMode get appMode => _appMode;
  String get downloadDir => _downloadDir;
  String get mountPath => _mountPath;
  bool get confirmDelete => _confirmDelete;
  int get atOnce => _atOnce;
  double get accentSat => _accentSat;
  double get monoL => _monoL;

  void _load() {
    _accent = _enumByName(Accent.values, _prefs.getString('accent'), Accent.green);
    _density =
        _enumByName(Density.values, _prefs.getString('density'), Density.mid);
    _dark = _prefs.getBool('dark') ?? true;
    _mode = _enumByName(ViewMode.values, _prefs.getString('mode'), ViewMode.text);
    _trove = _prefs.getBool('trove') ?? false;
    _appMode =
        _enumByName(AppMode.values, _prefs.getString('appMode'), AppMode.client);
    _downloadDir = _prefs.getString('downloadDir') ?? '~/Downloads';
    _mountPath = _prefs.getString('mountPath') ?? '~/Desktop/trove';
    _confirmDelete = _prefs.getBool('confirmDelete') ?? true;
    _atOnce = _prefs.getInt('atOnce') ?? 3;
    _accentSat = _prefs.getDouble('accentSat') ?? 1.0;
    _monoL = _prefs.getDouble('monoL') ?? 0.72;
  }

  T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  // Setters persist and notify.
  // Selecting a different accent resets its saturation to 1 (a fresh phosphor),
  // matching the source system — the drag is per-accent, from neutral.
  set accent(Accent v) => _set('accent', () {
        if (v != _accent) _accentSat = 1.0;
        _accent = v;
      }, () {
        _prefs.setString('accent', v.name);
        _prefs.setDouble('accentSat', _accentSat);
      });
  set accentSat(double v) => _set('accentSat',
      () => _accentSat = v.clamp(0.4, 2.6).toDouble(),
      () => _prefs.setDouble('accentSat', _accentSat));
  set monoL(double v) => _set('monoL',
      () => _monoL = v.clamp(0.12, 0.99).toDouble(),
      () => _prefs.setDouble('monoL', _monoL));
  set density(Density v) => _set('density', () => _density = v, () => _prefs.setString('density', v.name));
  set dark(bool v) => _set('dark', () => _dark = v, () => _prefs.setBool('dark', v));
  set mode(ViewMode v) => _set('mode', () => _mode = v, () => _prefs.setString('mode', v.name));
  set trove(bool v) => _set('trove', () => _trove = v, () => _prefs.setBool('trove', v));
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

  /// The palette for the current accent, tube setting, and drag intensity.
  Palette get palette =>
      Palette(_accent, _dark, sat: _accentSat, monoL: _monoL);
}
