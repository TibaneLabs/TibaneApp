import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/create_account_screen.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

Wallet _wallet(String id, String curve, {String name = 'Main'}) {
  final created = DateTime.utc(2026, 1, 1);
  return Wallet(
    id: id,
    name: name,
    curve: curve,
    threshold: 1,
    gen: 0,
    pubkey: '',
    chaincode: '',
    created: created,
    modified: created,
    keys: const [],
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('create-account screen keeps wallet and chain selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(750, 1334);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wallet = WalletService();
    addTearDown(wallet.dispose);
    AddAccountResult? result;
    final group = LogicalWallet([
      _wallet('sol', 'ed25519'),
      _wallet('eth', 'secp256k1'),
    ]);
    final secondGroup = LogicalWallet([
      _wallet('second-sol', 'ed25519', name: 'Secondary'),
      _wallet('second-eth', 'secp256k1', name: 'Secondary'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<AddAccountResult>(
                  MaterialPageRoute(
                    builder: (_) => CreateAccountScreen(
                      wallet: wallet,
                      target: const UnifiedAccount(
                        backend: AccountBackend.inapp,
                        chain: 'solana',
                        address: 'SolanaAddress',
                        label: 'Main - Account 1',
                        walletId: 'sol',
                        accountId: 'sol-account',
                      ),
                      groups: [group, secondGroup],
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Create New Account'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    final createButton = find.widgetWithText(FilledButton, 'Create');
    final before = tester.getRect(createButton);

    await tester.tap(find.text('Ethereum'));
    await tester.pumpAndSettle();
    expect(tester.getRect(createButton), before);

    await tester.tap(find.byKey(const Key('wallet-selector-trigger')));
    await tester.pumpAndSettle();
    final triggerBottom = tester
        .getBottomLeft(find.byKey(const Key('wallet-selector-trigger')))
        .dy;
    final optionsTop = tester
        .getTopLeft(find.byKey(const Key('wallet-selector-options')))
        .dy;
    expect(optionsTop, greaterThan(triggerBottom));
    await tester.tap(find.text('Secondary'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Trading');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result?.walletId, 'second-eth');
    expect(result?.chain, 'ethereum');
    expect(result?.name, 'Trading');
  });
}
