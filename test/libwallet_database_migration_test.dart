@TestOn('mac-os')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'native initialization migrates empty legacy WalletConnect topics',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tibane-libwallet-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/sql.db';
      final database = await databaseFactoryFfi.openDatabase(path);
      await database.execute(
        'CREATE TABLE "WalletConnect" ('
        '"Id" text PRIMARY KEY, "Topic" text, "PairingTopic" text, '
        '"State" text, "SymKey" text, "SelfPriv" text, "SelfPub" text, '
        '"PeerPub" text, "PeerMetadata" text, "Namespaces" text, '
        '"Expiry" text, "Created" text, "Updated" text)',
      );
      for (final entry in [
        {'Id': 'legacy-null', 'Topic': null, 'State': ''},
        {'Id': 'legacy-empty-1', 'Topic': '', 'State': ''},
        {'Id': 'legacy-empty-2', 'Topic': '', 'State': ''},
        {
          'Id': 'older-session',
          'Topic': 'valid-topic',
          'State': 'pairing',
          'Updated': '2026-10-01T00:00:00Z',
        },
        {
          'Id': 'active-session',
          'Topic': 'valid-topic',
          'State': 'active',
          'Updated': '2026-10-19T00:00:00Z',
        },
      ]) {
        await database.insert('WalletConnect', entry);
      }
      await database.close();

      final nativeBuild = Directory(
        '${Directory.current.path}/.dart_tool/hooks_runner/shared/libwallet/build',
      );
      final binary = nativeBuild.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.dylib'),
      );
      final client = LibwalletClient.initialize(
        directory.path,
        library: DynamicLibrary.open(binary.path),
      );
      try {
        await client.ready;
        expect(await client.info.version(), libwalletPackageVersion);
        expect(await client.info.ping(), 'pong');
      } finally {
        client.dispose();
      }

      final migrated = await databaseFactoryFfi.openDatabase(path);
      try {
        final rows = await migrated.query(
          'WalletConnect',
          columns: ['Id', 'Topic', 'State'],
        );
        expect(rows, [
          {'Id': 'active-session', 'Topic': 'valid-topic', 'State': 'active'},
        ]);
      } finally {
        await migrated.close();
      }
    },
  );
}
