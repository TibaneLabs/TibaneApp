import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/wallet/auto_backup_store.dart';

void main() {
  test(
    'concurrent wallet backups preserve previous wallets and legacy data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-backup-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/archive.json');
      await file.writeAsString('[{"filename":"legacy","data":"encrypted"}]');
      final store = AutoBackupStore(file);
      await Future.wait([
        store.put(
          AutoBackupEntry(
            id: 'a',
            name: 'Wallet A',
            updated: DateTime(2026),
            bundle: 'encrypted-a',
          ),
        ),
        store.put(
          AutoBackupEntry(
            id: 'b',
            name: 'Wallet B',
            updated: DateTime(2026),
            bundle: 'encrypted-b',
          ),
        ),
      ]);
      expect((await store.read()).map((entry) => entry.id).toSet(), {
        'legacy',
        'a',
        'b',
      });
      await store.remove('a');
      expect((await store.read()).map((entry) => entry.id).toSet(), {
        'legacy',
        'b',
      });
      expect(await File('${file.path}.tmp').exists(), false);
    },
  );
}
