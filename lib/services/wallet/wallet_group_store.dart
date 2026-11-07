import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Explicit creation/import relationships. Never infer ownership from labels.
class WalletGroupStore {
  static const preferenceKey = 'libw_logical_wallet_groups_v1';
  static Future<Map<String, String>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferenceKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid wallet groups');
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  static Future<void> associate(Iterable<String> walletIds) async {
    final ids = walletIds.toSet().toList()..sort();
    if (ids.isEmpty) return;
    await merge({for (final id in ids) id: ids.first});
  }

  static Future<void> merge(Map<String, String> groups) async {
    final existing = await read();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      preferenceKey,
      jsonEncode({...existing, ...groups}),
    )) {
      throw StateError('Could not persist wallet relationships');
    }
  }

  static Future<void> forget(Iterable<String> walletIds) async {
    final ids = walletIds.toSet();
    final groups = await read();
    final remaining = Map<String, String>.from(groups)
      ..removeWhere((id, _) => ids.contains(id));
    if (remaining.length == groups.length) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(preferenceKey, jsonEncode(remaining))) {
      throw StateError('Could not clear wallet relationships');
    }
  }
}
