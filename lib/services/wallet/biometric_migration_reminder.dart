import 'package:shared_preferences/shared_preferences.dart';

/// Local display preference, independent of whether any key was migrated.
class BiometricMigrationReminder {
  BiometricMigrationReminder._();

  static const _key = 'biometric_migration_reminder_at_v1';
  static const _hidden = -1;
  static const delay = Duration(days: 7);

  static Future<bool> isDue({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final remindAt = prefs.getInt(_key);
    if (remindAt == null) return true;
    if (remindAt == _hidden) return false;
    return (now ?? DateTime.now()).millisecondsSinceEpoch >= remindAt;
  }

  static Future<void> defer({
    required bool dontShowAgain,
    DateTime? now,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final remindAt = dontShowAgain
        ? _hidden
        : (now ?? DateTime.now()).add(delay).millisecondsSinceEpoch;
    if (!await prefs.setInt(_key, remindAt)) {
      throw StateError('biometric_migration_reminder_not_saved');
    }
  }
}
