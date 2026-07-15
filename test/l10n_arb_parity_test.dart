import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards every localization phase: each translated ARB must define exactly the
/// same key set as the English template (`app_en.arb`). Catches a translation
/// that was forgotten (missing key → English fallback slips through unnoticed)
/// or a stale/typo'd key (extra key). Runs from the package root, where
/// `flutter test` starts.
void main() {
  const dir = 'lib/l10n';

  Set<String> keysOf(String path) {
    final map = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    // Skip ARB metadata: "@@locale", "@@last_modified", and every "@key" entry.
    return map.keys.where((k) => !k.startsWith('@')).toSet();
  }

  test('every ARB has the same keys as the English template', () {
    final en = keysOf('$dir/app_en.arb');
    expect(en, isNotEmpty);

    for (final locale in const ['fr', 'ja', 'pt']) {
      final keys = keysOf('$dir/app_$locale.arb');
      expect(
        en.difference(keys),
        isEmpty,
        reason: 'app_$locale.arb is missing keys (untranslated)',
      );
      expect(
        keys.difference(en),
        isEmpty,
        reason: 'app_$locale.arb has keys not in the template (stale/typo)',
      );
    }
  });
}
