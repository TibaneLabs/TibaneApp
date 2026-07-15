import 'package:flutter/material.dart';

/// Ergonomic `BuildContext` accessors for the `X.of(context)` patterns used
/// most across the app — the same idea as `context.l10n`.
///
/// Two kinds live here, with different rules:
///
/// * **Dependency-registering** ([theme], [textTheme], [colorScheme],
///   [screenSize], [keyboardInset]) — reading them subscribes this widget to
///   rebuild when that value changes. Read them in `build`; never cache them in
///   a field/global; not safe in `initState`.
/// * **Ancestor lookups** ([navigator], [messenger], [unfocus], [showSnackBar])
///   — no dependency, no rebuild. Safe in callbacks and after `await` (guard
///   with `context.mounted`). This is why capturing `final messenger =
///   context.messenger;` before an `await` is fine — do that instead of
///   inlining `context.showSnackBar` across an async gap.
extension BuildContextX on BuildContext {
  // --- Theme (dependency) ---
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  // --- MediaQuery (dependency) — targeted *Of so we only rebuild on that
  //     slice, not on every MediaQuery change. ---
  Size get screenSize => MediaQuery.sizeOf(this);
  double get keyboardInset => MediaQuery.viewInsetsOf(this).bottom;

  // --- Ancestor lookups (no dependency; safe in callbacks / after await) ---
  NavigatorState get navigator => Navigator.of(this);
  ScaffoldMessengerState get messenger => ScaffoldMessenger.of(this);
  void unfocus() => FocusScope.of(this).unfocus();

  /// Inline SnackBar convenience. Don't use across an `await` — capture
  /// [messenger] first instead.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar,
  ) => ScaffoldMessenger.of(this).showSnackBar(snackBar);
}
