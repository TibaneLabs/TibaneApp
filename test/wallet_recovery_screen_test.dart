import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/settings/wallets_accounts_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_backup_restore_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_unlock_screen.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

class _Transport implements Transport {
  bool passwordOnly = true;
  int codesSent = 0;
  int passwordChecks = 0;
  Wallet get wallet => Wallet(
    id: 'wallet',
    name: 'Recovery fixture',
    curve: 'ed25519',
    threshold: 1,
    gen: 0,
    pubkey: 'public',
    chaincode: '',
    created: DateTime.utc(2026),
    modified: DateTime.utc(2026),
    keys: [
      for (final entry in {
        'password': 'Password',
        'second': passwordOnly ? 'Password' : 'StoreKey',
        'remote': 'RemoteKey',
      }.entries)
        WalletKey(
          id: entry.key,
          wallet: 'wallet',
          type: entry.value,
          key: entry.value == 'Password' ? 'password-public' : 'public',
          gen: 0,
        ),
    ],
  );
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Wallet/wallet') return wallet.toJson();
    if (path == 'StoreKey:derivePassword') {
      passwordChecks++;
      return {
        'Public_Key': params!['Password'] == 'fixture-password'
            ? 'password-public'
            : 'wrong-public',
      };
    }
    if (path == 'RemoteKey:reshare') {
      codesSent++;
      return {'session': 'session-$codesSent', 'length': 6};
    }
    throw StateError('Unexpected call $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport)
    : wallets = WalletApi(transport),
      storeKeys = StoreKeyApi(transport),
      remoteKeys = RemoteKeyApi(transport);
  @override
  final WalletApi wallets;
  @override
  final StoreKeyApi storeKeys;
  @override
  final RemoteKeyApi remoteKeys;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.transport) : client = _Client(transport);
  final _Transport transport;
  final _Client client;
  bool wrongRestorePassword = false;
  bool recoveryFailed = false;
  bool failRecovery = false;
  int recoveries = 0;
  int repairs = 0;
  final recoverySessions = <String>[];
  @override
  String get walletId => 'wallet';
  @override
  String? get error => recoveryFailed
      ? 'participant stopped responding'
      : wrongRestorePassword
      ? 'Wrong password for this backup'
      : super.error;
  @override
  Future<LibwalletClient> ensureClient() async => client;
  @override
  Future<bool> importFromBackup({
    required String backupJson,
    required String password,
  }) async {
    wrongRestorePassword = password != 'fixture-password';
    return !wrongRestorePassword;
  }

  @override
  Future<bool> recoverDeviceShareVia2fa({
    required String sessionToken,
    required String code,
    required String password,
  }) async {
    recoveries++;
    recoverySessions.add(sessionToken);
    recoveryFailed = failRecovery;
    return !failRecovery;
  }

  @override
  Future<bool> repairRemoteKeyVia2fa({
    required String sessionToken,
    required String code,
  }) async {
    repairs++;
    return true;
  }
}

class _Service extends WalletService {
  _Service(this.backend);
  final _Backend backend;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  Future<void> refreshAccounts() async {}
  @override
  Future<void> useLibwallet() async {}
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester,
  _Backend backend, {
  String language = 'en',
  bool restore = false,
  Size size = const Size(375, 667),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _Service(backend);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => restore
                      ? const InAppBackupRestoreScreen()
                      : const InAppUnlockScreen(),
                ),
              ),
              child: const Text('Open fixture'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture'));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(Scaffold).last));
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      testWidgets(
        'guided activation separates troubleshooting in $language at $size',
        (tester) async {
          final backend = _Backend(_Transport()..passwordOnly = false);
          final l10n = await _pump(
            tester,
            backend,
            language: language,
            size: size,
          );
          expect(find.text(l10n.inappUnlockRecommended), findsOneWidget);
          expect(find.text(l10n.inappUnlockSetupTitle), findsOneWidget);
          expect(find.text(l10n.inappUnlockRepairAction), findsNothing);
          expect(backend.transport.codesSent, 0);
          await _tap(tester, l10n.inappUnlockSetupTitle);
          expect(
            find.text(l10n.inappUnlockSingleDeviceWarning),
            findsOneWidget,
          );
          expect(find.byType(TextField), findsOneWidget);
          await _tap(tester, l10n.actionBack);
          await _tap(tester, l10n.inappUnlockTroubleshootingTitle);
          expect(find.text(l10n.inappUnlockRepairBody), findsOneWidget);
          await _tap(tester, l10n.inappUnlockRepairAction);
          expect(find.text(l10n.inappUnlockFlowRepairHeader), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(backend.transport.codesSent, 0);
          expect(backend.repairs, 0);
          expect(backend.recoveries, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets('password-only recovery needs no device key in $language', (
      tester,
    ) async {
      final backend = _Backend(_Transport());
      final l10n = await _pump(tester, backend, language: language);
      expect(find.text(l10n.inappUnlockPasswordOnlyReady), findsOneWidget);
      expect(find.text(l10n.inappUnlockSetupTitle), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(backend.transport.codesSent, 0);
      await _tap(tester, l10n.actionDone);
      expect(find.byType(InAppUnlockScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets('settings excludes Tokens NFTs Contacts in $language', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const WalletsAccountsScreen(),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(WalletsAccountsScreen)),
      );
      expect(find.text(l10n.tokensTitle), findsNothing);
      expect(find.text(l10n.walletsAccountsNftsTitle), findsNothing);
      expect(find.text(l10n.contactsTitle), findsNothing);
      expect(
        find.text(l10n.walletsAccountsManageAccountsTitle),
        findsOneWidget,
      );
      expect(find.text(l10n.walletsAccountsExportWalletTitle), findsOneWidget);
    });
  }

  testWidgets(
    'password-only backup restore skips 2FA setup after a password retry',
    (tester) async {
      final backend = _Backend(_Transport());
      final l10n = await _pump(tester, backend, restore: true);
      await tester.enterText(
        find.byType(TextField).first,
        'public backup fixture',
      );
      await tester.enterText(find.byType(TextField).last, 'wrong-password');
      await _tap(tester, l10n.backupRestoreButton);
      expect(find.text(l10n.walletErrorIncorrectPassword), findsWidgets);
      await tester.enterText(find.byType(TextField).last, 'fixture-password');
      await _tap(tester, l10n.backupRestoreButton);
      expect(find.byType(InAppBackupRestoreScreen), findsNothing);
      expect(find.byType(InAppUnlockScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(backend.transport.codesSent, 0);
      expect(backend.recoveries, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('StoreKey backup still requires device setup', (tester) async {
    final backend = _Backend(_Transport()..passwordOnly = false);
    final l10n = await _pump(tester, backend, restore: true);
    await tester.enterText(
      find.byType(TextField).first,
      'public backup fixture',
    );
    await tester.enterText(find.byType(TextField).last, 'fixture-password');
    await _tap(tester, l10n.backupRestoreButton);
    expect(find.text(l10n.backupRestoreSetupTitle), findsOneWidget);
    await _tap(tester, l10n.backupRestoreSetupNow);
    expect(find.byType(InAppUnlockScreen), findsOneWidget);
    expect(find.text(l10n.inappUnlockSetupTitle), findsOneWidget);
    expect(find.text(l10n.inappUnlockPasswordOnlyReady), findsNothing);
    expect(backend.transport.codesSent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'StoreKey recovery validates password and requests a new code after failure',
    (tester) async {
      final backend = _Backend(_Transport()..passwordOnly = false)
        ..failRecovery = true;
      final l10n = await _pump(tester, backend);
      await _tap(tester, l10n.inappUnlockSetupTitle);
      await tester.enterText(find.byType(TextField), 'wrong-password');
      await _tap(tester, l10n.inappUnlockSendCode);
      expect(find.text(l10n.walletErrorIncorrectPassword), findsOneWidget);
      expect(backend.transport.codesSent, 0);
      await tester.enterText(find.byType(TextField), 'fixture-password');
      await _tap(tester, l10n.inappUnlockSendCode);
      expect(backend.transport.codesSent, 1);
      await tester.enterText(find.byType(TextField).last, '123456');
      await _tap(tester, l10n.inappUnlockVerifySetup);
      expect(backend.recoveries, 1);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(l10n.walletErrorDetails), findsOneWidget);
      await _tap(tester, l10n.walletErrorDetails);
      expect(find.text('participant stopped responding'), findsOneWidget);
      Navigator.of(tester.element(find.byType(SelectableText))).pop();
      await tester.pumpAndSettle();
      backend.failRecovery = false;
      await _tap(tester, l10n.inappUnlockSendCode);
      await tester.enterText(find.byType(TextField).last, '654321');
      await _tap(tester, l10n.inappUnlockVerifySetup);
      expect(backend.recoverySessions, ['session-1', 'session-2']);
      expect(find.byType(InAppUnlockScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repair needs a fresh setup session and never reuses its code', (
    tester,
  ) async {
    final backend = _Backend(_Transport()..passwordOnly = false);
    final l10n = await _pump(tester, backend);
    await _tap(tester, l10n.inappUnlockTroubleshootingTitle);
    await _tap(tester, l10n.inappUnlockRepairAction);
    expect(find.byType(TextField), findsNothing);
    await _tap(tester, l10n.inappUnlockSendCode);
    await tester.enterText(find.byType(TextField), '123456');
    await _tap(tester, l10n.inappUnlockRepairAction);
    expect(backend.repairs, 1);
    expect(find.text(l10n.inappUnlockRepairFixed), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(backend.transport.passwordChecks, 0);
    await tester.enterText(find.byType(TextField), 'fixture-password');
    await _tap(tester, l10n.inappUnlockSendCode);
    expect(backend.transport.codesSent, 2);
    expect(tester.takeException(), isNull);
  });
}
