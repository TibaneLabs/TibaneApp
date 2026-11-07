import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/widgets/account_switcher_sheet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
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

class _Service extends WalletService {
  _Service({List<UnifiedAccount>? accounts})
    : visibleAccounts = accounts ?? _accounts;

  final List<UnifiedAccount> visibleAccounts;
  final selections = <UnifiedAccount>[];

  @override
  List<UnifiedAccount> get accounts => visibleAccounts;

  @override
  UnifiedAccount get currentAccount => _accounts[2];

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
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _Service(accounts: accounts);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAccountSwitcher(context),
              child: const Text('Open accounts'),
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
