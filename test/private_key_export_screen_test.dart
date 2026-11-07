import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/export_private_key_screen.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/gradient_button.dart';

const _fixture = 'PUBLIC-FIXTURE-NOT-A-REAL-PRIVATE-KEY';
const _account = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'solana',
  address: 'PublicFixtureAddress',
  label: 'Imported fixture',
  accountName: 'Imported fixture',
  accountIndex: 0,
  walletId: 'selected-wallet',
  accountId: 'selected-account',
);

class _Transport implements Transport {
  int threshold = 0;
  int exports = 0;
  bool failExport = false;
  Completer<void>? gate;
  Wallet get wallet => Wallet(
    id: 'selected-wallet',
    name: 'Fixture',
    curve: 'ed25519',
    threshold: threshold,
    gen: 0,
    pubkey: 'public-key',
    chaincode: '',
    created: DateTime.utc(2026),
    modified: DateTime.utc(2026),
    keys: [
      const WalletKey(
        id: 'selected-share',
        wallet: 'selected-wallet',
        type: 'StoreKey',
        key: 'store-public',
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
    if (path == 'Wallet/selected-wallet' && verb == 'GET') {
      return wallet.toJson();
    }
    if (path == 'Account/selected-account' && verb == 'GET') {
      return {
        'Id': 'selected-account',
        'Wallet': 'selected-wallet',
        'Name': 'Fixture',
        'Type': 'solana',
        'Index': 0,
        'Path': 'm',
        'Address': 'PublicFixtureAddress',
        'Pubkey': 'public-key',
        'Chaincode': '',
        'URI': '',
        'Created': DateTime.utc(2026).toIso8601String(),
        'Updated': DateTime.utc(2026).toIso8601String(),
      };
    }
    if (path == 'Wallet/selected-wallet:exportSecret') {
      exports++;
      await gate?.future;
      if (failExport) throw StateError(_fixture);
      return {
        'type': 'privateKey',
        'curve': 'ed25519',
        'format': 'keypair',
        'privateKey': _fixture,
      };
    }
    throw StateError('Unexpected call $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport)
    : wallets = WalletApi(transport),
      accounts = AccountApi(transport);
  @override
  final WalletApi wallets;
  @override
  final AccountApi accounts;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.transport) : client = _Client(transport);
  final _Transport transport;
  final _Client client;
  String? readWalletId;
  @override
  Future<LibwalletClient> ensureClient() async => client;
  @override
  String? get walletId => 'different-active-wallet';
  @override
  Future<String?> readStoreKeyPrivateForWallet(
    String walletId,
    WalletKey storeKey, {
    String? password,
  }) async {
    readWalletId = walletId;
    return 'public-fixture-unlock-key';
  }
}

class _WalletService extends WalletService {
  _WalletService(this.backend);
  final _Backend backend;
  @override
  LibwalletBackend get libwallet => backend;
}

Future<_Backend> _pump(
  WidgetTester tester, {
  String language = 'en',
  int threshold = 0,
}) async {
  tester.view.physicalSize = const Size(750, 1334);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final transport = _Transport()..threshold = threshold;
  final backend = _Backend(transport);
  final service = _WalletService(backend);
  addTearDown(() {
    backend.dispose();
    service.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ExportPrivateKeyScreen(account: _account),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

Future<void> _authorize(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('private-key-export-agree')));
  await tester.pumpAndSettle();
  final reveal = find.byKey(const Key('private-key-export-reveal'));
  await tester.ensureVisible(reveal);
  await tester.tap(reveal);
  await tester.pumpAndSettle();
  final l10n = AppLocalizations.of(
    tester.element(find.byType(ExportPrivateKeyScreen)),
  );
  await tester.tap(find.text(l10n.signSheetKeyDevice));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(GradientButton));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    testWidgets('consent and authorization precede reveal in $language', (
      tester,
    ) async {
      final backend = await _pump(tester, language: language);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('private-key-export-reveal')),
      );
      expect(button.onPressed, isNull);
      expect(backend.transport.exports, 0);
      expect(find.text(_fixture), findsNothing);
      await _authorize(tester);
      expect(find.text(_fixture), findsOneWidget);
      expect(backend.readWalletId, 'selected-wallet');
      expect(backend.walletId, 'different-active-wallet');
      expect(backend.transport.exports, 1);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add(call.arguments['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final copy = find.byKey(const Key('private-key-export-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, [_fixture]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text(_fixture), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('private-key-export-agree')),
            )
            .value,
        isFalse,
      );
    });
  }

  testWidgets('MPC accounts cannot reach native export', (tester) async {
    final backend = await _pump(tester, threshold: 1);
    await tester.tap(find.byKey(const Key('private-key-export-agree')));
    await tester.pumpAndSettle();
    final reveal = find.byKey(const Key('private-key-export-reveal'));
    await tester.ensureVisible(reveal);
    await tester.tap(reveal);
    await tester.pumpAndSettle();
    expect(backend.transport.exports, 0);
    expect(find.text(_fixture), findsNothing);
  });

  testWidgets('native export errors never expose secret text', (tester) async {
    final backend = await _pump(tester);
    backend.transport.failExport = true;
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    try {
      await _authorize(tester);
    } finally {
      debugPrint = previous;
    }
    expect(find.text(_fixture), findsNothing);
    expect(logs.any((message) => message.contains(_fixture)), isFalse);
    expect(
      find.text("Couldn't reveal or copy the private key. Please try again."),
      findsOneWidget,
    );
  });
}
