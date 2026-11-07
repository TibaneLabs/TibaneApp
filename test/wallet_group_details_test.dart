import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/wallets_management_screen.dart';
import 'package:tibaneapp/screens/wallet/export_private_key_screen.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/tibane_card.dart';

final _wallet = Wallet(
  id: 'wallet',
  name: 'Wallet fixture',
  curve: 'ed25519',
  threshold: 0,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: [],
);
final _account = Account(
  id: 'account',
  wallet: 'wallet',
  name: 'Imported Solana',
  type: 'solana',
  index: 0,
  path: '',
  address: 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y',
  uri: '',
  pubkey: '',
  chaincode: '',
  created: DateTime.utc(2026),
  updated: DateTime.utc(2026),
);

class _Accounts extends AccountsService {
  _Accounts() : super(LibwalletBackend(), MwaWalletBackend());
  @override
  List<Account> get rawAccounts => [_account];
}

class _WalletService extends WalletService {
  final _service = _Accounts();
  @override
  AccountsService get accountsService => _service;
  @override
  List<UnifiedAccount> get accounts => [
    UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: 'solana',
      address: _account.address,
      label: _account.name,
      accountName: _account.name,
      walletId: _wallet.id,
      accountId: _account.id,
      accountIndex: 0,
    ),
    const UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: 'bitcoin',
      address: 'bc1qrecognizedsidebaraddress',
      label: 'Bitcoin',
      accountName: 'Bitcoin',
      walletId: 'wallet',
      accountId: 'btc',
      isMainWalletContext: true,
    ),
  ];
  @override
  Future<void> refreshAccounts() async {}
  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('eligible imported accounts remain read-only in Manage Wallets', (
    tester,
  ) async {
    final service = _WalletService();
    addTearDown(service.dispose);
    final eligible = Wallet.fromJson({
      ..._wallet.toJson(),
      'Keys': [
        const WalletKey(
          id: 'share',
          wallet: 'wallet',
          type: 'StoreKey',
          key: 'public',
          gen: 0,
        ).toJson(),
      ],
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<WalletService>.value(
        value: service,
        child: MaterialApp(
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WalletGroupDetailsScreen(
            initialWallets: [eligible],
            activeWalletId: 'another-wallet',
            attachedWalletParents: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Imported Solana'));
    await tester.pumpAndSettle();
    expect(find.byType(ExportPrivateKeyScreen), findsNothing);
    expect(find.byType(WalletGroupDetailsScreen), findsOneWidget);
    expect(find.byIcon(Icons.key_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    testWidgets('wallet contents identifies accounts in $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _WalletService();
      addTearDown(service.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<WalletService>.value(
          value: service,
          child: MaterialApp(
            locale: Locale(language),
            theme: TibaneTheme.darkTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WalletGroupDetailsScreen(
              initialWallets: [_wallet],
              activeWalletId: 'wallet',
              attachedWalletParents: const {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Imported Solana'), findsOneWidget);
      expect(
        find.text(abbreviateAccountAddress(_account.address)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(
        find.text(abbreviateAccountAddress('bc1qrecognizedsidebaraddress')),
        findsOneWidget,
      );
      for (final card in tester.widgetList<TibaneCard>(
        find.byType(TibaneCard),
      )) {
        expect(card.onTap, isNull);
      }
      await tester.tap(find.text('Imported Solana'));
      await tester.pumpAndSettle();
      expect(find.byType(WalletGroupDetailsScreen), findsOneWidget);
    });
  }
}
