import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/l10n.dart';
import 'package:tibaneapp/models/token_account.dart';
import 'package:tibaneapp/screens/incinerator_screen.dart';
import 'package:tibaneapp/screens/settings_screen.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/rpc_service.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/reclaim_sol.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/widgets/token_icon.dart';

String _address(int i) => base58Encode(Uint8List(32)..fillRange(0, 32, i));
final _owner = _address(1);

TokenAccount _account(
  int id, {
  int amount = 0,
  int decimals = 6,
  bool token2022 = false,
  bool isNative = false,
  String? owner,
  String? mint,
  String? closeAuthority,
}) => TokenAccount(
  pubkey: _address(id),
  mint: mint ?? _address(10),
  owner: owner ?? _owner,
  amount: BigInt.from(amount),
  decimals: decimals,
  rentLamports: BigInt.from(2039280),
  isToken2022: token2022,
  isNative: isNative,
  closeAuthority: closeAuthority,
);

class _Rpc extends RpcService {
  _Rpc() : super.real();

  bool becameFunded = false;
  bool simulationFails = false;
  bool fundedToken2022 = false;
  int fundedAmount = 500000;
  bool noTokenAccounts = false;
  int simulations = 0;
  Uint8List? simulated;

  @override
  Future<List<TokenAccount>> getTokenAccountsByOwner(
    String owner, {
    bool token2022 = false,
  }) async {
    expect(owner, _owner);
    if (noTokenAccounts) return [];
    return token2022
        ? [
            _account(3, token2022: true, amount: fundedToken2022 ? 500000 : 0),
            _account(7, token2022: true, isNative: true),
          ]
        : [
            _account(2, amount: becameFunded ? 1 : 0),
            _account(4, amount: fundedToken2022 ? 0 : fundedAmount),
            _account(5, owner: _address(11)),
            _account(6, mint: wsolMint),
            _account(8, closeAuthority: _address(11)),
          ];
  }

  @override
  Future<String> getLatestBlockhash() async => _address(12);

  @override
  Future<List<Map<String, dynamic>>> getAssetsByOwner(
    String owner, {
    int page = 1,
    int limit = 1000,
  }) async => [];

  @override
  Future<Map<String, TokenMetadata>> getAssetBatch(List<String> mints) async =>
      {
        for (final mint in mints)
          mint: TokenMetadata(mint: mint, name: 'Funded token', symbol: 'FIX'),
      };

  @override
  Future<Map<String, dynamic>> simulateTransaction(Uint8List txBytes) async {
    simulations++;
    simulated = txBytes;
    return {'err': simulationFails ? 'fixture error' : null};
  }

  @override
  Future<List<SolanaSignatureStatus>> getSignatureStatuses(
    List<String> signatures,
  ) async => [for (final _ in signatures) SolanaSignatureStatus.confirmed];
}

class _Prices extends BalancesStore {
  _Prices(super.wallet);

  double? _price;

  void publish(double price) {
    _price = price;
    notifyListeners();
  }

  @override
  List<TokenHolding> get holdings => [
    TokenHolding(
      mint: _address(10),
      symbol: 'FIX',
      name: 'Funded token',
      balance: BigInt.from(500000),
      decimals: 6,
      uiBalance: 0.5,
      priceUsd: _price,
    ),
  ];
}

class _Wallet extends WalletService {
  final sent = <Uint8List>[];
  int refreshes = 0;

  @override
  bool get isConnected => true;
  @override
  String get publicKey => _owner;
  @override
  WalletKind get kind => WalletKind.mwa;
  @override
  UnifiedAccount get currentAccount => UnifiedAccount(
    backend: AccountBackend.mwa,
    chain: 'solana',
    address: _owner,
    label: 'Fixture',
  );

  @override
  Future<List<String?>> signAndSendTransactions(List<Uint8List> txs) async {
    sent.addAll(txs);
    return [for (final _ in txs) 'fixture-signature'];
  }

  @override
  void notifyTxCommitted() => refreshes++;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test('reclaim builds only CloseAccount for both token programs', () {
    final accounts = [_account(2), _account(3, token2022: true)];
    final ixs = buildReclaimSolInstructions(accounts, _owner);
    expect(ixs, hasLength(2));
    expect(ixs.map((ix) => base58Encode(ix.programId)), [
      splTokenProgramId,
      token2022ProgramId,
    ]);
    for (var i = 0; i < ixs.length; i++) {
      expect(ixs[i].data, [9]);
      expect(ixs[i].accounts.map((a) => base58Encode(a.pubkey)), [
        accounts[i].pubkey,
        _owner,
        _owner,
      ]);
      expect(ixs[i].accounts.last.isSigner, isTrue);
    }
  });

  test(
    'reclaim burns exactly one raw unit before closing in either program',
    () {
      for (final token2022 in [false, true]) {
        final dust = _account(2, amount: 1, token2022: token2022);
        final ixs = buildReclaimSolInstructions([dust], _owner);
        expect(ixs, hasLength(2));
        expect(ixs.first.data, [15, 1, 0, 0, 0, 0, 0, 0, 0, 6]);
        expect(ixs.last.data, [9]);
        expect(ixs.last.accounts.map((a) => base58Encode(a.pubkey)), [
          dust.pubkey,
          _owner,
          _owner,
        ]);
        expect(
          ixs.map((ix) => base58Encode(ix.programId)),
          everyElement(token2022 ? token2022ProgramId : splTokenProgramId),
        );
      }
    },
  );

  test(
    'funded, wrapped SOL, foreign and delegated-close accounts are rejected',
    () {
      for (final account in [
        _account(2, amount: 2),
        _account(2, amount: 1, decimals: 0),
        _account(2, amount: 1, decimals: 9),
        _account(3, mint: wsolMint),
        _account(4, isNative: true, token2022: true),
        _account(5, owner: _address(11)),
        _account(6, closeAuthority: _address(11)),
      ]) {
        expect(
          () => buildReclaimSolInstructions([account], _owner),
          throwsArgumentError,
        );
      }
    },
  );

  testWidgets(
    'Settings shows eligible SOL beside Reclaim and refreshes an outdated preview',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rpc = _Rpc();
      final wallet = _Wallet();
      final compliance = UkComplianceService();
      RpcService.testInstance = rpc;
      addTearDown(() => RpcService.testInstance = null);
      addTearDown(wallet.dispose);
      addTearDown(compliance.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<WalletService>.value(value: wallet),
            ChangeNotifierProvider<UkComplianceService>.value(
              value: compliance,
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('settings-reclaim-sol'));
      final title = find.descendant(
        of: card,
        matching: find.text('Reclaim SOL'),
      );
      final badge = find.text('0.004 SOL');
      expect(badge, findsOneWidget);
      expect(
        tester.getCenter(badge).dx,
        greaterThan(tester.getCenter(title).dx),
      );
      expect(
        tester.getCenter(badge).dy,
        closeTo(tester.getCenter(title).dy, 1),
      );
      expect(
        tester.getRect(card).right - tester.getRect(badge).right,
        closeTo(27.8, 0.1),
      );

      rpc.noTokenAccounts = true;
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.text('0.000 SOL'), findsOneWidget);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(wallet.sent, isEmpty);
    },
  );

  for (final scenario in [
    'success',
    'dust success',
    'funded after preview',
    'simulation failed',
  ]) {
    testWidgets('Reclaim SOL in Settings: $scenario', (tester) async {
      final rpc = _Rpc();
      if (scenario == 'dust success') rpc.fundedAmount = 1;
      final wallet = _Wallet();
      final compliance = UkComplianceService();
      RpcService.testInstance = rpc;
      addTearDown(() => RpcService.testInstance = null);
      addTearDown(wallet.dispose);
      addTearDown(compliance.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<WalletService>.value(value: wallet),
            ChangeNotifierProvider<UkComplianceService>.value(
              value: compliance,
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(scenario == 'dust success' ? '0.006 SOL' : '0.004 SOL'),
        findsOneWidget,
      );
      rpc.becameFunded = scenario == 'funded after preview';
      rpc.simulationFails = scenario == 'simulation failed';
      await tester.tap(find.byKey(const Key('settings-reclaim-sol')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      if (scenario == 'success' || scenario == 'dust success') {
        expect(wallet.sent, hasLength(1));
        expect(wallet.sent.single, rpc.simulated);
        expect(wallet.refreshes, 1);
        expect(find.textContaining('Confirmed closures: 2 of 2'), findsNothing);
        expect(find.text('0.000 SOL'), findsOneWidget);
      } else {
        expect(wallet.sent, isEmpty);
        expect(rpc.simulations, rpc.simulationFails ? 1 : 0);
        expect(find.text('0.004 SOL'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Incinerator lists funded assets without the reclaim estimate', (
    tester,
  ) async {
    final wallet = _Wallet();
    RpcService.testInstance = _Rpc()..fundedAmount = 1;
    addTearDown(() => RpcService.testInstance = null);
    addTearDown(wallet.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WalletService>.value(
        value: wallet,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: IncineratorScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Funded token'), findsOneWidget);
    expect(find.text('0.000001'), findsOneWidget);
    expect(find.text('0.00'), findsNothing);
    expect(find.text('Tokens (1)'), findsOneWidget);
    expect(find.textContaining('does not sell them for SOL'), findsOneWidget);
    await tester.tap(find.text('Funded token'));
    await tester.pumpAndSettle();
    expect(find.text('Burn'), findsOneWidget);
    expect(find.textContaining('0.0020 SOL'), findsNothing);
    await tester.tap(find.text('Burn'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('cannot be')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Cancel')),
    );
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(wallet.sent, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Incinerator styles token rows and uses the Wallet USD price', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final wallet = _Wallet();
    final prices = _Prices(wallet);
    RpcService.testInstance = _Rpc()..fundedToken2022 = true;
    addTearDown(() => RpcService.testInstance = null);
    addTearDown(wallet.dispose);
    addTearDown(prices.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletService>.value(value: wallet),
          ChangeNotifierProvider<BalancesStore>.value(value: prices),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: IncineratorScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.local_fire_department), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    final warning = find.textContaining('does not sell them for SOL');
    final bodySmall = Theme.of(tester.element(warning)).textTheme.bodySmall!;
    expect(
      tester.widget<Text>(warning).style!.fontSize,
      closeTo(bodySmall.fontSize! * 1.2, 0.001),
    );
    expect(tester.widget<TokenIcon>(find.byType(TokenIcon)).size, 44.85);
    expect(
      tester.widget<Text>(find.text('Funded token')).style!.fontSize,
      16.1,
    );
    final amount = formatTokenAmount(BigInt.from(500000), 6);
    expect(tester.widget<Text>(find.text(amount)).style!.fontSize, 12.65);
    expect(find.text('Token-2022'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);

    prices.publish(2);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(r'$1.00')).style!.fontSize, 11.25);
    expect(find.text('Token-2022'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
