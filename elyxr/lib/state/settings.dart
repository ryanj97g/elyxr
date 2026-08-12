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
  double _accentSat = 1.0; // 0.25–3.2 (wider: deeper muting, punchier max)
  double _monoL = 0.72; // 0.12–0.99
  // The chosen terminal (glass) font family — one of kTermFaces' families.
  String _termFont = 'VT323';
  // Nostalgia Mode: the master switch for all the retro whimsy (the matrix
  // screensaver, cursor trail, minigame, sounds…). Off on a fresh install — the
  // plain experience is the premium instrument; this opts into the fun. Remembered
  // once chosen, because having to switch it back on at every launch made a
  // preference behave like a party trick.
  bool _nostalgia = false;
  // "2000's DEMO MODE": when on (with Nostalgia on), the built-in easter-egg
  // keygen soundtrack is the auto-playing music source. Off by default, so it's
  // opt-in rather than hijacking the player the moment Nostalgia turns on — and
  // so a trove folder you're streaming stays your music source.
  bool _demoMode2000s = false;
  // Demo Mode's four contents. Each is only live while Nostalgia and Demo Mode
  // are both on; on by default so switching Demo Mode on gives the whole thing,
  // and turning one off is the deliberate act.
  bool _screensaver = true;
  bool _lightshow = true;
  bool _oscilloscope = true;
  bool _soundtrack = true;
  bool _shakeForTailscale = false;
  // Whether the settings screen is showing. Kept here, not in the home widget's
  // own state, so a rebuild (e.g. while dragging a colour swatch) can never wipe
  // it and bounce you out of settings. In-memory; resets to the files view on
  // launch.
  bool _inSettings = false;

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
  String get termFont => _termFont;
  bool get nostalgia => _nostalgia;
  bool get demoMode2000s => _demoMode2000s;
  bool get shakeForTailscale => _shakeForTailscale;
  bool get inSettings => _inSettings;

  /// The four sub-toggles as stored, whether or not they're reachable.
  bool get screensaver => _screensaver;
  bool get lightshow => _lightshow;
  bool get oscilloscope => _oscilloscope;
  bool get soundtrack => _soundtrack;

  /// Demo Mode is only a thing while Nostalgia is on; the four toggles are only
  /// visible while Demo Mode is on. Read these rather than re-deriving the gate,
  /// so every surface agrees on what is live.
  bool get demoActive => _nostalgia && _demoMode2000s;
  bool get showScreensaver => demoActive && _screensaver;
  bool get showLightshow => demoActive && _lightshow;
  bool get showOscilloscope => demoActive && _oscilloscope;
  bool get playSoundtrack => demoActive && _soundtrack;

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
    _termFont = _prefs.getString('termFont') ?? 'VT323';
    // If the saved face no longer exists (e.g. a font that was removed), fall
    // back to the default rather than render in a missing family.
    if (!termFaces.any((f) => f.family == _termFont)) _termFont = 'VT323';
    _nostalgia = _prefs.getBool('nostalgia') ?? false;
    _demoMode2000s = _prefs.getBool('demoMode2000s') ?? false;
    _screensaver = _prefs.getBool('screensaver') ?? true;
    _lightshow = _prefs.getBool('lightshow') ?? true;
    _oscilloscope = _prefs.getBool('oscilloscope') ?? true;
    _soundtrack = _prefs.getBool('soundtrack') ?? true;
    _shakeForTailscale = _prefs.getBool('shakeForTailscale') ?? false;
    // Apply the chosen terminal face before the first frame builds. It governs
    // everything on the glass — the body text and the ticker/readouts alike —
    // since the ticker is part of the screen, not a separate face. Only the
    // metal chassis font stays fixed.
    Fonts.glass = _termFont;
    Fonts.mono = _termFont;
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
      () => _accentSat = v.clamp(0.25, 3.2).toDouble(),
      () => _prefs.setDouble('accentSat', _accentSat));
  set monoL(double v) => _set('monoL',
      () => _monoL = v.clamp(0.12, 0.99).toDouble(),
      () => _prefs.setDouble('monoL', _monoL));
  // Swapping the terminal face updates the live font behind every glass() and
  // mono() call — the whole screen, ticker included, re-skins on the next
  // rebuild. The chassis (metal) face is untouched.
  set termFont(String v) => _set('termFont', () {
        _termFont = v;
        Fonts.glass = v;
        Fonts.mono = v;
      }, () => _prefs.setString('termFont', v));
  // Remembered across launches. Turning it on doesn't start the easter-egg
  // soundtrack by itself — only the toggles in Settings do that — so restoring it
  // brings the whimsy back without music beginning the moment the app opens.
  set nostalgia(bool v) {
    if (_nostalgia == v) return;
    _set('nostalgia', () => _nostalgia = v, () => _prefs.setBool('nostalgia', v));
  }

  set shakeForTailscale(bool v) {
    if (_shakeForTailscale == v) return;
    _set('shakeForTailscale', () => _shakeForTailscale = v,
        () => _prefs.setBool('shakeForTailscale', v));
  }

  /// Re-scan the on-disk custom-fonts folder (uncommitted drops included) and
  /// rebuild so any new faces appear in the picker. Dev convenience.
  Future<void> reloadFonts() async {
    await reloadCustomFontsFromDisk();
    notifyListeners();
  }

  set inSettings(bool v) {
    if (_inSettings == v) return;
    _inSettings = v;
    notifyListeners();
  }
  set demoMode2000s(bool v) => _set('demoMode2000s',
      () => _demoMode2000s = v, () => _prefs.setBool('demoMode2000s', v));
  set screensaver(bool v) => _set('screensaver',
      () => _screensaver = v, () => _prefs.setBool('screensaver', v));
  set lightshow(bool v) => _set('lightshow',
      () => _lightshow = v, () => _prefs.setBool('lightshow', v));
  set oscilloscope(bool v) => _set('oscilloscope',
      () => _oscilloscope = v, () => _prefs.setBool('oscilloscope', v));
  set soundtrack(bool v) => _set('soundtrack',
      () => _soundtrack = v, () => _prefs.setBool('soundtrack', v));
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
