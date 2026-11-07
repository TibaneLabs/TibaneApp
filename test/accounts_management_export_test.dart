import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/accounts_management_screen.dart';
import 'package:tibaneapp/screens/wallet/export_private_key_screen.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/mwa_wallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

class _Backend extends LibwalletBackend {
  String? activeId;
  @override
  String? get accountId => activeId;
}

class _Accounts extends AccountsService {
  _Accounts(this.raw, this.wallet)
    : super(LibwalletBackend(), MwaWalletBackend());
  final Account raw;
  final Wallet wallet;
  @override
  List<Account> get rawAccounts => [raw];
  @override
  Map<String, Wallet> get walletsById => {wallet.id: wallet};
}

class _Service extends WalletService {
  _Service({
    int threshold = 0,
    int index = 0,
    bool main = false,
    bool active = false,
    bool matchingKey = true,
    String chain = 'solana',
    int keyCount = 1,
  }) {
    final wallet = Wallet(
      id: 'fixture-wallet',
      name: 'Fixture wallet',
      curve: 'ed25519',
      threshold: threshold,
      gen: 0,
      pubkey: 'public-fixture-key',
      chaincode: '',
      created: DateTime.utc(2026),
      modified: DateTime.utc(2026),
      keys: List.generate(
        keyCount,
        (i) => WalletKey(
          id: 'share-$i',
          wallet: 'fixture-wallet',
          type: 'StoreKey',
          key: 'public-store-key',
          gen: 0,
        ),
      ),
    );
    final raw = Account(
      id: 'fixture-account',
      wallet: wallet.id,
      name: 'Selected fixture',
      type: chain,
      index: index,
      path: 'm',
      address: 'PublicFixtureAddress',
      uri: '',
      pubkey: matchingKey ? wallet.pubkey : 'different-public-key',
      chaincode: '',
      created: DateTime.utc(2026),
      updated: DateTime.utc(2026),
    );
    account = UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: chain,
      address: raw.address,
      label: raw.name,
      accountName: raw.name,
      walletId: wallet.id,
      accountId: raw.id,
      accountIndex: index,
      isMainWalletContext: main,
    );
    store = _Accounts(raw, wallet);
    backend.activeId = active ? raw.id : 'another-account';
  }
  late final UnifiedAccount account;
  late final _Accounts store;
  final backend = _Backend();
  int switches = 0;
  @override
  AccountsService get accountsService => store;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  List<UnifiedAccount> get accounts => [account];
  @override
  UnifiedAccount? get currentAccount =>
      backend.activeId == account.accountId ? account : null;
  @override
  Future<void> refreshAccounts() async {}
  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount account, {
    String? networkId,
  }) async {
    switches++;
    backend.activeId = account.accountId;
    return true;
  }

  @override
  Future<void> refreshBalances() async {}
  @override
  void dispose() {
    store.dispose();
    backend.dispose();
    super.dispose();
  }
}

Future<void> _open(
  WidgetTester tester,
  _Service service,
  String language,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AccountsManagementScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Selected fixture'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final active in [true, false]) {
      testWidgets('$language imported account export, active=$active', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(750, 1334);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _Service(active: active);
        addTearDown(service.dispose);
        await _open(tester, service, language);
        expect(service.switches, 0);
        await tester.tap(find.byKey(const Key('account-export-private-key')));
        await tester.pumpAndSettle();
        expect(find.byType(ExportPrivateKeyScreen), findsOneWidget);
        expect(
          tester
              .widget<ExportPrivateKeyScreen>(
                find.byType(ExportPrivateKeyScreen),
              )
              .account,
          same(service.account),
        );
        expect(
          find.byKey(const Key('private-key-export-agree')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('private-key-export-reveal')),
              )
              .onPressed,
          isNull,
        );
        expect(service.switches, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  final excluded = <String, _Service Function()>{
    'native': () => _Service(main: true),
    'MPC created or promoted': () => _Service(threshold: 1, keyCount: 3),
    'derived': () => _Service(index: 1),
    'different root public key': () => _Service(matchingKey: false),
    'multiple shares': () => _Service(keyCount: 2),
    'unsupported chain': () => _Service(chain: 'bitcoin'),
  };
  for (final entry in excluded.entries) {
    testWidgets('${entry.key} has no private-key export option', (
      tester,
    ) async {
      final service = entry.value();
      addTearDown(service.dispose);
      await _open(tester, service, 'en');
      expect(find.byKey(const Key('account-export-private-key')), findsNothing);
      expect(find.text('Export private key'), findsNothing);
      expect(service.switches, 0);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('selecting an inactive account remains an explicit action', (
    tester,
  ) async {
    final service = _Service();
    addTearDown(service.dispose);
    await _open(tester, service, 'en');
    expect(service.switches, 0);
    await tester.tap(find.text('Use this account'));
    await tester.pumpAndSettle();
    expect(service.switches, 1);
    expect(find.byType(AccountsManagementScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
