import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Wallet, WalletKey;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/accounts_management_screen.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_private_key_screen.dart';
import 'package:tibaneapp/screens/wallet/wallet_create_options_screen.dart';
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_sheet.dart';
import 'package:libwallet/libwallet.dart' show CatCardPairing;
import 'package:tibaneapp/screens/wallet/add_hardware_wallet_screen.dart';
import 'package:tibaneapp/screens/wallet/widgets/hardware_status.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet/accounts_service.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

final _accounts = [
  for (final chain in [
    'solana',
    'ethereum',
    'bitcoin',
    'bitcoin-cash',
    'dogecoin',
    'litecoin',
  ])
    UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: chain,
      address: 'public-$chain-address-for-display-testing',
      label: 'Account 1',
      walletId: 'wallet',
      accountId: 'native-$chain',
      accountName: 'Account 1',
      accountIndex: 0,
      isMainWalletContext: true,
    ),
  const UnifiedAccount(
    backend: AccountBackend.inapp,
    chain: 'solana',
    address: 'public-added-account-address-for-display-testing',
    label: 'Account 2',
    walletId: 'wallet',
    accountId: 'added-solana',
    accountName: 'Account 2',
    accountIndex: 1,
  ),
];

class _FixtureAccounts extends AccountsService {
  _FixtureAccounts(
    super.libwallet,
    super.mwa,
    this.walletsById,
    this.attachedWalletParents,
    this.walletGroups,
  );

  @override
  final Map<String, Wallet> walletsById;

  @override
  final Map<String, String> attachedWalletParents;

  @override
  final Map<String, String> walletGroups;
}

class _Service extends WalletService {
  _Service({
    List<UnifiedAccount>? accounts,
    this.fixtureWallets,
    this.attachedWalletParents = const {},
    this.walletGroups = const {},
  }) : visibleAccounts = accounts ?? _accounts;

  final List<UnifiedAccount> visibleAccounts;
  final Map<String, Wallet>? fixtureWallets;
  final Map<String, String> attachedWalletParents;
  final Map<String, String> walletGroups;
  late final _fixtureAccounts = _FixtureAccounts(
    libwallet,
    mwa,
    fixtureWallets!,
    attachedWalletParents,
    walletGroups,
  );
  final selections = <UnifiedAccount>[];

  @override
  List<UnifiedAccount> get accounts => visibleAccounts;

  @override
  UnifiedAccount get currentAccount =>
      fixtureWallets == null ? _accounts[2] : visibleAccounts.first;

  @override
  AccountsService get accountsService =>
      fixtureWallets == null ? super.accountsService : _fixtureAccounts;

  @override
  Future<void> refreshAccounts() async {}

  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount acct, {
    String? networkId,
  }) async {
    selections.add(acct);
    return true;
  }
}

Finder _row(UnifiedAccount account) =>
    find.byKey(ValueKey('account-switcher-row-${account.id}'));

Finder _textIn(UnifiedAccount account, String text) =>
    find.descendant(of: _row(account), matching: find.text(text));

Future<_Service> _open(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
  List<UnifiedAccount>? accounts,
  Map<String, Wallet>? wallets,
  Map<String, String> attachedWalletParents = const {},
  Map<String, String> walletGroups = const {},
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _Service(
    accounts: accounts,
    fixtureWallets: wallets,
    attachedWalletParents: attachedWalletParents,
    walletGroups: walletGroups,
  );
  if (navigatorKey != null) installHardwareWalletUi(service, navigatorKey);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showAccountSwitcher(context),
                  child: const Text('Open accounts'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const AccountsManagementScreen(),
                    ),
                  ),
                  child: const Text('Manage test accounts'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open accounts'));
  await tester.pumpAndSettle();
  return service;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'a lone private key offers wallet creation or independent import',
    (tester) async {
      final imported = Wallet(
        id: 'wallet',
        name: 'Imported',
        curve: 'ed25519',
        protocol: 'frost',
        threshold: 0,
        gen: 0,
        pubkey: '',
        chaincode: '',
        created: DateTime(2020),
        modified: DateTime(2020),
        keys: const [
          WalletKey(
            id: 'key',
            wallet: 'wallet',
            type: 'StoreKey',
            key: '',
            gen: 0,
          ),
        ],
      );
      await _open(
        tester,
        accounts: [_accounts.first],
        wallets: {'wallet': imported},
      );

      Future<void> openMenu() async {
        final add = find.text('Add New');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(of: dialog, matching: find.text('Add New')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.byType(Text)),
          findsNWidgets(4),
        );
        final cancel = tester.widget<FilledButton>(
          find.descendant(
            of: dialog,
            matching: find.widgetWithText(FilledButton, 'Cancel'),
          ),
        );
        expect(
          cancel.style?.backgroundColor?.resolve({}),
          TibaneColors.textDim,
        );
        expect(find.text('Create New Account'), findsNothing);
      }

      await openMenu();
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      expect(find.byType(WalletCreateOptionsScreen), findsOneWidget);
      expect(
        find.byKey(const Key('wallet-create-seed-option')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('wallet-create-mpc-option')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openMenu();
      await tester.tap(find.text('Import Another Account'));
      await tester.pumpAndSettle();
      final screen = tester.widget<InAppImportPrivateKeyScreen>(
        find.byType(InAppImportPrivateKeyScreen),
      );
      expect(screen.groups, isEmpty);
    },
  );

  testWidgets(
    'an imported selection offers wallet creation even beside an MPC wallet',
    (tester) async {
      const imported = UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: 'solana',
        address: 'imported-public-address',
        label: 'Imported account',
        accountId: 'imported-account',
        walletId: 'imported',
      );
      Wallet wallet(String id, int threshold) => Wallet(
        id: id,
        name: id,
        curve: 'ed25519',
        protocol: 'frost',
        threshold: threshold,
        gen: 0,
        pubkey: '',
        chaincode: '',
        created: DateTime(2020),
        modified: DateTime(2020),
        keys: const [],
      );
      await _open(
        tester,
        accounts: [imported, _accounts.first],
        wallets: {
          'wallet': wallet('wallet', 1),
          'imported': wallet('imported', 0),
        },
        attachedWalletParents: const {'imported': 'wallet'},
      );
      final add = find.text('Add New');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('Create New Account'), findsNothing);
      expect(find.text('Import Another Account'), findsOneWidget);

      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      expect(find.byType(WalletCreateOptionsScreen), findsOneWidget);
    },
  );

  testWidgets('manage accounts groups chains and hides only the sidebar row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    Wallet wallet(String id, String curve) => Wallet(
      id: id,
      name: 'Combined wallet',
      curve: curve,
      threshold: 1,
      gen: 0,
      pubkey: '',
      chaincode: '',
      created: DateTime.utc(2026),
      modified: DateTime.utc(2026),
      keys: const [],
    );
    UnifiedAccount account(
      String name,
      String chain,
      String walletId,
      int day, {
      bool main = false,
    }) => UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: chain,
      address: 'public-$name-account-address',
      label: 'Combined wallet - $name',
      accountName: name,
      walletName: 'Combined wallet',
      accountId: name,
      walletId: walletId,
      createdAt: DateTime.utc(2026, 1, day),
      isMainWalletContext: main,
    );
    final eth = account('Ethereum account', 'ethereum', 'evm', 1, main: true);
    final sol = account('Solana account', 'solana', 'sol', 2, main: true);
    final added = account('Added account', 'solana', 'sol', 3);
    final service = await _open(
      tester,
      size: const Size(320, 568),
      accounts: [sol, added, eth],
      wallets: {
        'sol': wallet('sol', 'ed25519'),
        'evm': wallet('evm', 'secp256k1'),
      },
      walletGroups: const {'sol': 'group', 'evm': 'group'},
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(AccountSwitcherSheet)),
    );
    await tester.tap(find.byTooltip(l10n.actionClose));
    await tester.pumpAndSettle();
    Future<void> open(String name) async {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    await open('Manage test accounts');
    expect(find.text('Combined wallet'), findsOneWidget);
    expect(find.textContaining('Combined wallet -'), findsNothing);
    expect(find.text('Added accounts'), findsNothing);
    expect(find.textContaining('From wallet:'), findsNothing);
    expect(find.byIcon(Icons.copy), findsNothing);
    final rows = [
      for (final a in [eth, sol, added])
        find.byKey(ValueKey('managed-account-${a.id}')),
    ];
    expect(
      tester.getTopLeft(rows[0]).dy,
      lessThan(tester.getTopLeft(rows[1]).dy),
    );
    expect(
      tester.getTopLeft(rows[1]).dy,
      lessThan(tester.getTopLeft(rows[2]).dy),
    );
    final address = find.descendant(
      of: rows[1],
      matching: find.text(abbreviateAccountAddress(sol.address)),
    );
    expect(tester.widget<Text>(address).style!.fontSize, 13.2);
    final hide = find.descendant(
      of: rows[1],
      matching: find.byTooltip(l10n.accountsHideInSidebar),
    );
    await tester.tap(hide);
    await tester.pumpAndSettle();
    final show = find.descendant(
      of: rows[1],
      matching: find.byTooltip(l10n.accountsShowInSidebar),
    );
    expect(show, findsOneWidget);
    expect(service.currentAccount, same(sol));
    expect(service.accounts, contains(sol));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await open('Open accounts');
    expect(_row(sol), findsNothing);
    expect(_row(eth), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.actionClose));
    await tester.pumpAndSettle();
    await open('Manage test accounts');
    await tester.tap(show);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await open('Open accounts');
    expect(_row(sol), findsOneWidget);
    expect(service.selections, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    testWidgets('Add hardware wallet opens the device chooser: $language', (
      tester,
    ) async {
      await _open(tester, language: language, size: const Size(320, 568));
      final l10n = AppLocalizations.of(
        tester.element(find.byType(AccountSwitcherSheet)),
      );
      final add = find.text(l10n.hwAddTitle);
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(AccountSwitcherSheet), findsNothing);
      expect(find.byType(AddHardwareWalletScreen), findsOneWidget);
      expect(find.text('CatCard'), findsOneWidget);
      expect(find.text('Ledger'), findsOneWidget);
      expect(find.text(l10n.hwAirgapTitle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('CatCard pairing asks the person to compare the code', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final service = await _open(tester, navigatorKey: navigatorKey);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(AccountSwitcherSheet)),
    );
    final answer = service.hardware.confirmCatCardPairing!(
      CatCardPairing.fromJson(const {'id': 'p1', 'code': '123 456'}),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.catCardPairTitle), findsOneWidget);
    expect(find.text('123 456'), findsOneWidget);

    await tester.tap(find.text(l10n.catCardPairSame));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(find.text('123 456'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      testWidgets('native labels match added accounts: $language $size', (
        tester,
      ) async {
        await _open(tester, language: language, size: size);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(AccountSwitcherSheet)),
        );
        expect(find.text(l10n.accountSwitcherAdditionalHeader), findsNothing);
        final added = _accounts.last;
        final addedTitle = _textIn(added, 'Account 2');
        final addedAddress = _textIn(
          added,
          abbreviateAccountAddress(added.address),
        );
        final titleStyle = tester.widget<Text>(addedTitle).style!;
        final addressStyle = tester.widget<Text>(addedAddress).style!;
        expect(titleStyle.fontSize, 17.25);
        expect(titleStyle.fontWeight, FontWeight.w600);
        expect(addressStyle.fontSize, 12.65);
        expect(addressStyle.fontFamily, GoogleFonts.dmSans().fontFamily);

        for (final account in _accounts.take(6)) {
          final title = _textIn(account, chainLabel(account.chain));
          final address = _textIn(
            account,
            abbreviateAccountAddress(account.address),
          );
          expect(title, findsOneWidget);
          expect(address, findsOneWidget);
          expect(tester.widget<Text>(title).style, titleStyle);
          expect(tester.widget<Text>(address).style, addressStyle);
          expect(
            tester.getTopLeft(title).dx,
            closeTo(tester.getTopLeft(addedTitle).dx, 0.01),
          );
          expect(
            tester.getTopLeft(address).dx,
            closeTo(tester.getTopLeft(addedAddress).dx, 0.01),
          );
          expect(
            tester.getTopLeft(address).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
          );
        }
        expect(find.text('Account 1'), findsNothing);
        expect(
          find.descendant(
            of: _row(_accounts[2]),
            matching: find.byIcon(Icons.check_circle),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('native and added rows share one wallet background', (
    tester,
  ) async {
    const external = UnifiedAccount(
      backend: AccountBackend.mwa,
      chain: 'solana',
      address: 'public-external-account-address',
      label: 'External account',
      accountName: 'External account',
    );
    await _open(tester, accounts: [..._accounts, external]);
    final group = find.byKey(
      const ValueKey('account-switcher-group-unmatched-in-app-accounts'),
    );
    expect(group, findsOneWidget);
    expect(tester.widget<Material>(group).color, isNot(Colors.transparent));
    for (final account in _accounts) {
      expect(
        find.descendant(of: group, matching: _row(account)),
        findsOneWidget,
      );
      final row = tester.widget<Material>(_row(account));
      expect(
        row.color,
        account == _accounts[2]
            ? isNot(Colors.transparent)
            : Colors.transparent,
      );
    }
    expect(find.descendant(of: group, matching: _row(external)), findsNothing);
    expect(
      tester.widget<Material>(_row(external)).color,
      isNot(Colors.transparent),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wallet with only added accounts also has a shared background', (
    tester,
  ) async {
    await _open(tester, accounts: [_accounts.last]);
    final group = find.byKey(
      const ValueKey('account-switcher-group-unmatched-in-app-accounts'),
    );
    expect(
      find.descendant(of: group, matching: _row(_accounts.last)),
      findsOneWidget,
    );
    expect(
      tester.widget<Material>(_row(_accounts.last)).color,
      Colors.transparent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('added rows follow all native rows in creation order', (
    tester,
  ) async {
    final earlier = UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: 'ethereum',
      address: 'public-earlier-ethereum-account-address',
      label: 'Earlier Ethereum',
      accountName: 'Earlier Ethereum',
      accountId: 'earlier-ethereum',
      walletId: 'wallet',
      accountIndex: 1,
      createdAt: DateTime.utc(2026, 11, 1),
    );
    final later = UnifiedAccount(
      backend: AccountBackend.inapp,
      chain: 'solana',
      address: 'public-later-solana-account-address',
      label: 'Later Solana',
      accountName: 'Later Solana',
      accountId: 'later-solana',
      walletId: 'wallet',
      accountIndex: 1,
      createdAt: DateTime.utc(2026, 11, 2),
    );
    await _open(tester, accounts: [later, ..._accounts.take(6), earlier]);
    expect(
      tester.getTopLeft(_row(earlier)).dy,
      greaterThan(tester.getBottomLeft(_row(_accounts[5])).dy),
    );
    expect(
      tester.getTopLeft(_row(later)).dy,
      greaterThan(tester.getBottomLeft(_row(earlier)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy uses full native and added addresses without selecting', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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
    final service = await _open(tester);
    for (final account in [_accounts.first, _accounts.last]) {
      final copy = find.descendant(
        of: _row(account),
        matching: find.byIcon(Icons.copy),
      );
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
    }
    expect(copied, [_accounts.first.address, _accounts.last.address]);
    expect(service.selections, isEmpty);
    expect(find.byType(AccountSwitcherSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network title selects the corresponding native account', (
    tester,
  ) async {
    final service = await _open(tester);
    await tester.tap(_textIn(_accounts[1], 'Ethereum'));
    await tester.pumpAndSettle();
    expect(service.selections, [_accounts[1]]);
    expect(find.byType(AccountSwitcherSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('added account remains selectable in the shared background', (
    tester,
  ) async {
    final service = await _open(tester);
    final title = _textIn(_accounts.last, 'Account 2');
    await tester.ensureVisible(title);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(service.selections, [_accounts.last]);
    expect(find.byType(AccountSwitcherSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
