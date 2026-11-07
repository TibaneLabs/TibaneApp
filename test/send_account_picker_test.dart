import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType, Wallet;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/widgets/send_account_picker.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

Network network(NetworkType type, String chain, String symbol) => Network(
  id: 'net-$chain',
  type: type,
  chainId: chain,
  name: symbol,
  rpc: '',
  currencySymbol: symbol,
  currencyDecimals: 9,
  blockExplorer: '',
  testNet: false,
  priority: 0,
  created: DateTime.utc(2026),
  updated: DateTime.utc(2026),
);

UnifiedAccount account(
  String id,
  String chain, {
  String address = '123456789ABCDEFGHJKLMNPQRSTUVWXYZ123456789',
  String wallet = 'main',
  String name = 'Account',
  bool main = false,
  String? networkId,
  String? networkChainId,
}) => UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: chain,
  address: address,
  label: '$wallet - $name',
  walletId: wallet,
  accountId: id,
  accountName: name,
  accountIndex: main ? 0 : 1,
  isMainWalletContext: main,
  networkId: networkId,
  networkChainId: networkChainId,
);

Wallet wallet(String id, String name) => Wallet(
  id: id,
  name: name,
  curve: 'ed25519',
  threshold: 1,
  gen: 0,
  pubkey: '',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: const [],
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test(
    'includes native, added and imported Solana accounts across wallets',
    () {
      final accounts = [
        account('native', 'solana', main: true),
        account('added', 'solana'),
        account('imported', 'solana', wallet: 'import'),
        account('second-wallet', 'solana', wallet: 'other'),
        account('eth', 'ethereum'),
        account('btc', 'bitcoin'),
        account('empty', 'solana', address: ''),
        account('invalid', 'solana', address: 'N/A'),
      ];
      expect(
        sendRecipientsForNetwork(
          accounts,
          network(NetworkType.solana, 'solana', 'SOL'),
        ).map((a) => a.id),
        ['native', 'added', 'imported', 'second-wallet'],
      );
    },
  );

  test('EVM rejects other families and explicitly bound different chains', () {
    final accounts = [
      account('eth', 'ethereum'),
      account('evm', 'evm'),
      account('bound-eth', 'ethereum', networkChainId: '1'),
      account('polygon', 'ethereum', networkChainId: '137'),
      account('bound-other', 'ethereum', networkId: 'other-network'),
      account('sol', 'solana'),
      account('btc', 'bitcoin'),
    ];
    expect(
      sendRecipientsForNetwork(
        accounts,
        network(NetworkType.evm, '1', 'ETH'),
      ).map((a) => a.id),
      ['eth', 'evm', 'bound-eth'],
    );
  });

  test('excludes the sender and its duplicate address, not its wallet', () {
    final sender = account('sender', 'solana', address: 'SenderAddress');
    final sibling = account('sibling', 'solana', address: 'OtherAddress');
    final duplicate = account(
      'duplicate',
      'solana',
      address: 'SenderAddress',
      wallet: 'imported',
    );
    expect(
      sendRecipientsForNetwork(
        [sender, sibling, duplicate],
        network(NetworkType.solana, 'solana', 'SOL'),
        senderAccountId: sender.id,
        senderAddress: sender.address,
      ),
      [sibling],
    );
  });

  test('EVM self-address comparison ignores checksum casing', () {
    expect(
      sendRecipientsForNetwork(
        [
          account('self', 'ethereum', address: '0xAbCd1234'),
          account('other', 'ethereum', address: '0x98761234'),
        ],
        network(NetworkType.evm, '1', 'ETH'),
        senderAddress: '0xabcd1234',
      ).map((a) => a.id),
      ['other'],
    );
  });

  test('Solana address comparison remains case sensitive', () {
    expect(
      sendRecipientsForNetwork(
        [
          account('self', 'solana', address: 'SenderAddress'),
          account('other', 'solana', address: 'senderAddress'),
        ],
        network(NetworkType.solana, 'solana', 'SOL'),
        senderAddress: 'SenderAddress',
      ).map((a) => a.id),
      ['other'],
    );
  });

  testWidgets('sender is absent and sender-only list shows empty state', (
    tester,
  ) async {
    final sender = account('sender', 'solana', address: 'SenderAddress');
    final recipient = account('recipient', 'solana', address: 'OtherAddress');
    Future<void> pump(List<UnifiedAccount> accounts) => tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SendAccountPicker(
            network: network(NetworkType.solana, 'solana', 'SOL'),
            accounts: accounts,
            wallets: [wallet('main', 'Main')],
            senderAccountId: sender.id,
            senderAddress: sender.address,
          ),
        ),
      ),
    );
    await pump([sender, recipient]);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('send-recipient-${sender.id}')), findsNothing);
    expect(
      find.byKey(ValueKey('send-recipient-${recipient.id}')),
      findsOneWidget,
    );
    await pump([sender]);
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(SendAccountPicker)),
    );
    expect(find.text(l10n.sendNoAccountsForNetwork('SOL')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (chain, symbol) in [
    ('bitcoin', 'BTC'),
    ('bitcoin-cash', 'BCH'),
    ('dogecoin', 'DOGE'),
    ('litecoin', 'LTC'),
  ]) {
    test(
      '$symbol does not offer accounts from other Bitcoin-family chains',
      () {
        final accounts = [
          for (final c in kBitcoinFamilyChainOrder)
            account(c, c, networkChainId: c),
        ];
        expect(
          sendRecipientsForNetwork(
            accounts,
            network(NetworkType.bitcoin, chain, symbol),
          ).map((a) => a.id),
          [chain],
        );
      },
    );
  }

  test(
    'unknown network fails closed and external Solana stays Solana-only',
    () {
      const external = UnifiedAccount(
        backend: AccountBackend.mwa,
        chain: 'solana',
        address: 'ExternalAddress',
        label: 'Seed Vault',
      );
      expect(
        sendRecipientsForNetwork([
          external,
        ], network(NetworkType.solana, 'solana', 'SOL')),
        [external],
      );
      expect(
        sendRecipientsForNetwork([
          external,
        ], network(NetworkType.evm, '1', 'ETH')),
        isEmpty,
      );
      expect(
        sendRecipientsForNetwork([
          external,
        ], network(NetworkType.unknown, 'unknown', '?')),
        isEmpty,
      );
    },
  );

  testWidgets('groups wallets and returns the full selected address', (
    tester,
  ) async {
    final native = account(
      'native',
      'solana',
      name: 'Main account',
      main: true,
    );
    final imported = account(
      'imported',
      'solana',
      wallet: 'import',
      name: 'Imported account',
    );
    UnifiedAccount? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('Open'),
              onPressed: () async {
                selected = await showModalBottomSheet<UnifiedAccount>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => SizedBox(
                    height: 500,
                    child: SendAccountPicker(
                      network: network(NetworkType.solana, 'solana', 'SOL'),
                      accounts: [
                        native,
                        imported,
                        account(
                          'other',
                          'solana',
                          wallet: 'other',
                          name: 'Other account',
                        ),
                        account('eth', 'ethereum', name: 'Hidden ETH'),
                      ],
                      wallets: [
                        wallet('main', 'Main wallet'),
                        wallet('import', 'Imported technical wallet'),
                        wallet('other', 'Second wallet'),
                      ],
                      attachedWalletParents: const {'import': 'main'},
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Main wallet'), findsOneWidget);
    expect(find.text('Second wallet'), findsOneWidget);
    expect(find.text('Imported technical wallet'), findsNothing);
    expect(find.text('Hidden ETH'), findsNothing);
    expect(
      find.text(abbreviateAccountAddress(imported.address)),
      findsNWidgets(3),
    );
    await tester.tap(find.byKey(const ValueKey('send-recipient-imported')));
    await tester.pumpAndSettle();
    expect(selected, same(imported));
    expect(selected!.address, imported.address);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'pt', 'fr', 'ja']) {
    testWidgets('compact layout and empty state in $locale', (tester) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> pump(List<UnifiedAccount> accounts) => tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SendAccountPicker(
              network: network(NetworkType.solana, 'solana', 'SOL'),
              accounts: accounts,
              wallets: [
                wallet(
                  'main',
                  'A very long wallet name that wraps on small screens',
                ),
              ],
            ),
          ),
        ),
      );
      await pump([
        account(
          'long',
          'solana',
          name: 'A very long account name that must stay on one line',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('send-recipient-long')), findsOneWidget);
      await pump([]);
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SendAccountPicker)),
      );
      expect(find.text(l10n.sendNoAccountsForNetwork('SOL')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
