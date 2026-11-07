import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/wallet_export_format.dart';

Wallet _wallet({
  String protocol = 'mnemonic',
  int threshold = 0,
  int shares = 1,
}) => Wallet(
  id: 'fixture',
  name: 'Fixture',
  curve: 'ed25519',
  protocol: protocol,
  threshold: threshold,
  gen: 0,
  pubkey: 'public',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: [
    for (var i = 0; i < shares; i++)
      WalletKey(
        id: 'key-$i',
        wallet: 'fixture',
        type: 'Password',
        key: 'public-$i',
        gen: 0,
      ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only ordinary seed wallets export words by default', () {
    expect(
      WalletExportPolicy.formatFor(_wallet()),
      WalletExportFormat.recoveryPhrase,
    );
    for (final wallet in [
      _wallet(protocol: 'frost', threshold: 1, shares: 3),
      _wallet(protocol: 'dkls23', threshold: 1, shares: 3),
      _wallet(protocol: 'frost'),
      _wallet(protocol: ''),
      _wallet(threshold: 1),
      _wallet(shares: 2),
    ]) {
      expect(WalletExportPolicy.formatFor(wallet), WalletExportFormat.backup);
    }
  });

  test(
    'backup import origin persists and only changes its wallet format',
    () async {
      await WalletExportPolicy.recordBackupImports({'fixture', 'other'});
      final ids = await WalletExportPolicy.backupImports();
      expect(ids, {'fixture', 'other'});
      expect(
        WalletExportPolicy.formatFor(_wallet(), backupImports: ids),
        WalletExportFormat.backup,
      );
      await WalletExportPolicy.forget({'fixture'});
      expect(await WalletExportPolicy.backupImports(), {'other'});
      expect(
        WalletExportPolicy.formatFor(
          _wallet(),
          backupImports: await WalletExportPolicy.backupImports(),
        ),
        WalletExportFormat.recoveryPhrase,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'libw_backup_import_origin_v1_other'});
      expect(prefs.getBool(prefs.getKeys().single), isTrue);
    },
  );
}
