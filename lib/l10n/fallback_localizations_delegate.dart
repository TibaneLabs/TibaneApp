import 'package:flutter/widgets.dart';

/// Wraps a third-party [LocalizationsDelegate] so it reports support for **every**
/// locale, loading [fallbackLocale] whenever the wrapped delegate doesn't cover
/// the active one.
///
/// Why: `phone_form_field` ships many locales (including `fr` and `pt`) but not
/// `ja`. Because `ja` is one of the app's supported locales, Flutter's debug
/// build prints "This application's locale, ja, is not supported by all of its
/// localization delegates" (from `Localizations._debugCheckLocalizations`, an
/// assert — debug-only, never a crash) and the phone widget has no localization
/// for Japanese. Wrapping the phone delegates makes them fall back to English
/// for `ja`, silencing the warning and giving the country picker English labels
/// instead of none.
///
/// [type] is forwarded to the wrapped delegate so `Localizations.of<T>` still
/// resolves the real resource object under its true type.
class FallbackLocalizationsDelegate extends LocalizationsDelegate<dynamic> {
  final LocalizationsDelegate<dynamic> inner;
  final Locale fallbackLocale;

  const FallbackLocalizationsDelegate(this.inner, this.fallbackLocale);

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<dynamic> load(Locale locale) => inner.isSupported(locale)
      ? inner.load(locale)
      : inner.load(fallbackLocale);

  @override
  Type get type => inner.type;

  @override
  bool shouldReload(LocalizationsDelegate<dynamic> old) =>
      old is! FallbackLocalizationsDelegate || old.inner != inner;
}
