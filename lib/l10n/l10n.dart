import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

// Re-export so importing this one file gives both the `context.l10n` extension
// and the `AppLocalizations` type (used for delegates, `supportedLocales`, and
// function parameters).
export 'gen/app_localizations.dart';

/// Ergonomic access to the app's localized strings:
/// `context.l10n.someKey` instead of `AppLocalizations.of(context).someKey`.
///
/// Read it from a build `context`: `AppLocalizations.of` resolves the *current*
/// locale AND registers the `InheritedWidget` dependency that rebuilds this
/// widget when the language changes. For that reason, never cache the returned
/// object in a field or a global — doing so would freeze the locale and break
/// live language switching (see `LocaleController`). Also unsafe in
/// `initState`/`dispose`, exactly like calling `AppLocalizations.of` directly.
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
