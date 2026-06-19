import 'package:flutter/foundation.dart';

/// Logs a user-facing error to the debug console — **debug builds only**.
///
/// [debugPrint] on its own logs even in release mode, which would write error
/// detail (addresses, amounts, exception text) into the production device log.
/// The [kDebugMode] guard keeps that out of release builds while the message
/// stays readable during development via `flutter run` / `flutter logs`.
///
/// If production diagnostics are ever needed, route to a remote reporter
/// (Sentry/Crashlytics, etc.) from this single place instead of logging raw to
/// the device console.
///
/// Call with the message pre-formatted:
/// ```dart
/// logError('[Foo._bar] save failed: $e');
/// ```
/// or pass the error / stack trace separately:
/// ```dart
/// logError('[Foo._bar] save failed', e, st);
/// ```
void logError(String message, [Object? error, StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  final buffer = StringBuffer(message);
  if (error != null) buffer.write(': $error');
  if (stackTrace != null) buffer.write('\n$stackTrace');
  debugPrint(buffer.toString());
}
