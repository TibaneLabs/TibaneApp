import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_private_key_screen.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _seed =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _scalar =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Backend extends LibwalletBackend {
  _Backend(this.chain);
  final String chain;
  int imports = 0;
  bool duplicate = true;
  lw.Account get existing => lw.Account(
    id: 'existing-account',
    wallet: 'another-wallet',
    name: 'Existing account',
    type: chain,
    index: 0,
    path: 'm',
    address: chain == 'solana'
        ? 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y'
        : '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf',
    uri: '',
    pubkey: 'public',
    chaincode: '',
    created: DateTime.utc(2026),
    updated: DateTime.utc(2026),
  );
  @override
  Future<ImportedWalletAccount> importPrivateKey({
    required String privateKey,
    required String curve,
    required String accountType,
    required String walletName,
    required String accountName,
    String? expectedAddress,
    String? format,
  }) async {
    imports++;
    if (duplicate) throw PrivateKeyAccountExistsException(existing);
    return ImportedWalletAccount(
      wallet: lw.Wallet(
        id: existing.wallet,
        name: walletName,
        curve: curve,
        threshold: 0,
        gen: 0,
        pubkey: existing.pubkey,
        chaincode: '',
        created: DateTime.utc(2026),
        modified: DateTime.utc(2026),
        keys: const [],
      ),
      account: existing,
    );
  }
}

class _Wallet extends WalletService {
  _Wallet(String chain) : backend = _Backend(chain);
  final _Backend backend;
  int switches = 0;
  bool failSwitch = false;
  bool removed = false;
  UnifiedAccount? selected;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  List<UnifiedAccount> get accounts => removed
      ? []
      : [
          UnifiedAccount(
            backend: AccountBackend.inapp,
            chain: backend.chain,
            address: backend.existing.address,
            label: 'Existing account',
            accountName: 'Existing account',
            accountId: 'existing-account',
            walletId: 'another-wallet',
          ),
        ];
  @override
  Future<void> refreshAccounts() async {}
  @override
  Future<void> useLibwallet() async {}
  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount account, {
    String? networkId,
  }) async {
    switches++;
    if (failSwitch) return false;
    selected = account;
    return true;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _openImport(
  WidgetTester tester,
  _Wallet wallet,
  String language,
) async {
  tester.view.physicalSize = const Size(750, 1334);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: wallet,
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
                  builder: (_) => const InAppImportPrivateKeyScreen(),
                ),
              ),
              child: const Text('Import fixture'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Import fixture'));
  await tester.pumpAndSettle();
  if (wallet.backend.chain == 'ethereum') {
    await tester.tap(find.text('Ethereum'));
    await tester.pumpAndSettle();
  }
  final l10n = AppLocalizations.of(
    tester.element(find.byType(InAppImportPrivateKeyScreen)),
  );
  await tester.enterText(
    find.byKey(const Key('private-key-input')),
    wallet.backend.chain == 'solana' ? _seed : _scalar,
  );
  await tester.enterText(find.byType(TextField).last, 'New name');
  final next = find.text(l10n.mnemonicContinueButton);
  await tester.ensureVisible(next);
  await tester.tap(next);
  await tester.pumpAndSettle();
  return l10n;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final chain in ['solana', 'ethereum']) {
    for (final language in ['en', 'pt', 'fr', 'ja']) {
      for (final open in [true, false]) {
        testWidgets('$chain duplicate warning $language, open=$open', (
          tester,
        ) async {
          final wallet = _Wallet(chain);
          addTearDown(wallet.dispose);
          final l10n = await _openImport(tester, wallet, language);
          expect(
            find.text(l10n.privateKeyAlreadyImportedTitle),
            findsOneWidget,
          );
          expect(find.text(l10n.privateKeyAlreadyImportedBody), findsOneWidget);
          expect(
            find.text(
              abbreviateAccountAddress(wallet.backend.existing.address),
            ),
            findsOneWidget,
          );
          expect(wallet.switches, 0);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('private-key-input')))
                .controller!
                .text,
            isEmpty,
          );
          await tester.tap(
            open
                ? find.byKey(const Key('open-existing-import-account'))
                : find.text(l10n.actionCancel),
          );
          await tester.pumpAndSettle();
          expect(wallet.backend.imports, 1);
          expect(wallet.switches, open ? 1 : 0);
          expect(wallet.selected?.accountId, open ? 'existing-account' : null);
          expect(
            find.byType(InAppImportPrivateKeyScreen),
            open ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      }
      testWidgets('$chain normal import completes without MPC in $language', (
        tester,
      ) async {
        final wallet = _Wallet(chain)..backend.duplicate = false;
        addTearDown(wallet.dispose);
        final l10n = await _openImport(tester, wallet, language);
        expect(find.text(l10n.privateKeyDoneTitle), findsOneWidget);
        expect(find.text(l10n.privateKeyDoneBody), findsOneWidget);
        expect(find.text(wallet.backend.existing.address), findsOneWidget);
        expect(find.byKey(const Key('private-key-input')), findsNothing);
        expect(find.text(l10n.privateKeyPromoteAction), findsNothing);
        expect(find.text(l10n.privateKeySkipAction), findsNothing);
        expect(find.text(l10n.privateKeyExportWarning), findsNothing);
        expect(find.byType(FilledButton), findsOneWidget);
        expect(wallet.backend.imports, 1);
        expect(wallet.selected?.accountId, 'existing-account');
        final done = find.text(l10n.actionDone);
        await tester.ensureVisible(done);
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byType(InAppImportPrivateKeyScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final removed in [false, true]) {
    testWidgets(
      'opening an unavailable account fails safely, removed=$removed',
      (tester) async {
        final wallet = _Wallet('solana')..failSwitch = true;
        addTearDown(wallet.dispose);
        await _openImport(tester, wallet, 'en');
        wallet.removed = removed;
        await tester.tap(find.byKey(const Key('open-existing-import-account')));
        await tester.pumpAndSettle();
        expect(wallet.selected, isNull);
        expect(find.byType(InAppImportPrivateKeyScreen), findsOneWidget);
        expect(wallet.backend.imports, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
