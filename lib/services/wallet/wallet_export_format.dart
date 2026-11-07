import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:shared_preferences/shared_preferences.dart';

enum WalletExportFormat { recoveryPhrase, backup }

bool isNormalMnemonicWallet(Wallet wallet) =>
    wallet.protocol == 'mnemonic' &&
    wallet.threshold == 0 &&
    wallet.keys.length == 1 &&
    wallet.keys.single.isPassword;

/// Only provenance is stored here, never recovery words or credentials.
class WalletExportPolicy {
  static const _backupPrefix = 'libw_backup_import_origin_v1_';

  static WalletExportFormat formatFor(
    Wallet wallet, {
    Set<String> backupImports = const {},
  }) => isNormalMnemonicWallet(wallet) && !backupImports.contains(wallet.id)
      ? WalletExportFormat.recoveryPhrase
      : WalletExportFormat.backup;

  static Future<Set<String>> backupImports() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in prefs.getKeys())
        if (key.startsWith(_backupPrefix) && prefs.getBool(key) == true)
          key.substring(_backupPrefix.length),
    };
  }

  static Future<void> recordBackupImports(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    for (final id in ids) {
      if (!await prefs.setBool('$_backupPrefix$id', true)) {
        throw StateError('Could not persist wallet import origin');
      }
    }
  }

  static Future<void> forget(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    for (final id in ids) {
      if (!await prefs.remove('$_backupPrefix$id')) {
        throw StateError('Could not clear wallet import origin');
      }
    }
  }
}
