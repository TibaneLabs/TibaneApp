import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';

/// Persists the user's chosen app language and exposes it to [MaterialApp].
///
/// A null [locale] means **"System default"**: [MaterialApp.locale] stays null,
/// so Flutter resolves the UI language against the device's preferred locales
/// via `resolveAppLocale` (see `main.dart`), falling back to English when the
/// device language isn't one we ship. When the user picks a specific language,
/// that [Locale] is stored and drives the app until they change it again.
///
/// Mirrors the ChangeNotifier + SharedPreferences pattern used by
/// [BrowserPreferences]; registered in the app's `MultiProvider`.
class LocaleController extends ChangeNotifier {
  static const _prefsKey = 'app_locale';

  Locale? _locale;
  bool _ready = false;

  /// True once [load] has finished restoring the persisted choice.
  bool get isReady => _ready;

  /// The user's explicit choice, or null for "System default" (auto-detect).
  Locale? get locale => _locale;

  /// Locales the app ships translations for. Mirrors
  /// [AppLocalizations.supportedLocales] so the settings list can't drift from
  /// what's actually generated.
  List<Locale> get supported => AppLocalizations.supportedLocales;

  /// Restore the saved language (if any) from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _locale = decode(prefs.getString(_prefsKey));
    _ready = true;
    notifyListeners();
  }

  /// Set the app language. Pass null to select "System default" (clears the
  /// stored value and reverts to device auto-detection). No-op when unchanged.
  Future<void> setLocale(Locale? locale) async {
    if (sameLocale(_locale, locale)) return;
    _locale = locale;
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, encode(locale));
    }
    notifyListeners();
  }

  /// Whether [candidate] is the currently selected locale. Pass null for the
  /// "System default" row.
  bool isSelected(Locale? candidate) => sameLocale(_locale, candidate);

  /// Serialize a locale to `language` or `language_COUNTRY` for storage.
  @visibleForTesting
  static String encode(Locale l) =>
      (l.countryCode == null || l.countryCode!.isEmpty)
      ? l.languageCode
      : '${l.languageCode}_${l.countryCode}';

  /// Parse a stored code back into a [Locale]; null/empty → null (System
  /// default). Pure, for unit testing.
  @visibleForTesting
  static Locale? decode(String? code) {
    if (code == null || code.isEmpty) return null;
    final parts = code.split('_');
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return Locale(parts[0], parts[1]);
    }
    return Locale(parts[0]);
  }

  /// Locale equality on language+country only (ignores scriptCode). Treats two
  /// nulls as equal. Pure, for unit testing.
  @visibleForTesting
  static bool sameLocale(Locale? a, Locale? b) {
    if (a == null || b == null) return a == b;
    return a.languageCode == b.languageCode && a.countryCode == b.countryCode;
  }
}
