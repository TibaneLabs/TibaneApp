import 'dart:convert';
import 'dart:io';

class AutoBackupEntry {
  AutoBackupEntry({
    required this.id,
    required this.name,
    required this.updated,
    required this.bundle,
  });
  final String id;
  final String name;
  final DateTime updated;
  final String bundle;
}

/// A versioned archive retains separate encrypted bundles for every wallet.
/// Serial read/modify/write and rename prevent concurrent writes or a failed
/// write from replacing the last complete archive with a truncated file.
class AutoBackupStore {
  AutoBackupStore(this.file);
  final File file;
  Future<void> _tail = Future.value();

  Future<List<AutoBackupEntry>> read() async {
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    final json = jsonDecode(text);
    if (json is List) {
      return [
        AutoBackupEntry(
          id: 'legacy',
          name: 'Backup',
          updated: await file.lastModified(),
          bundle: text,
        ),
      ];
    }
    if (json is! Map ||
        json['format'] != 'tibane-auto-backups-v2' ||
        json['backups'] is! Map) {
      throw const FormatException('Invalid automatic backup archive');
    }
    final entries = <AutoBackupEntry>[];
    for (final entry in (json['backups'] as Map).entries) {
      final value = entry.value as Map;
      entries.add(
        AutoBackupEntry(
          id: entry.key as String,
          name: value['name'] as String,
          updated: DateTime.parse(value['updated'] as String),
          bundle: value['bundle'] as String,
        ),
      );
    }
    return entries..sort((a, b) => b.updated.compareTo(a.updated));
  }

  Future<void> _update(
    Future<List<AutoBackupEntry>> Function(List<AutoBackupEntry>) update,
  ) {
    final result = _tail.then((_) async {
      final entries = await update(await read());
      final temporary = File('${file.path}.tmp');
      try {
        await temporary.writeAsString(
          jsonEncode({
            'format': 'tibane-auto-backups-v2',
            'backups': {
              for (final e in entries)
                e.id: {
                  'name': e.name,
                  'updated': e.updated.toIso8601String(),
                  'bundle': e.bundle,
                },
            },
          }),
          flush: true,
        );
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> put(AutoBackupEntry entry) => _update(
    (entries) async => [...entries.where((e) => e.id != entry.id), entry],
  );
  Future<void> remove(String id) =>
      _update((entries) async => entries.where((e) => e.id != id).toList());
}
