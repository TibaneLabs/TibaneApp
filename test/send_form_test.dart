import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/utils/amount.dart';

final _network = Network(
  id: 'solana-mainnet',
  type: NetworkType.solana,
  chainId: 'mainnet',
  name: 'Solana',
  rpc: '',
  currencySymbol: 'SOL',
  currencyDecimals: 9,
  blockExplorer: '',
  testNet: false,
  priority: 0,
  created: DateTime.utc(2026),
  updated: DateTime.utc(2026),
);
const _source = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'solana',
  address: '11111111111111111111111111111111',
  label: 'Source',
  accountId: 'source',
  walletId: 'wallet',
  accountName: 'Source',
);
const _recipient = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'solana',
  address: 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y',
  label: 'Recipient',
  accountId: 'recipient',
  walletId: 'wallet',
  accountName: 'Recipient',
);

class _Backend extends LibwalletBackend {
  Amount? auditSimulatedAmount;
  @override
  Future<TransactionSimulation> simulateSend({
    required String to,
    required Amount amount,
    String? asset,
    MaxSendableResult? maxPlan,
  }) async {
    auditSimulatedAmount = amount;
    throw StateError('Offline audit stops before signing');
  }

  int maxCalls = 0;
  String? recipient;
  bool failMax = false;
  Completer<void>? maxGate;
  @override
  Network? get currentNetwork => _network;
  @override
  Future<Network?> refreshCurrentNetwork() async => _network;
  @override
  Future<MaxSendableResult> maxSendable({String? asset, String? to}) async {
    maxCalls++;
    recipient = to;
    await maxGate?.future;
    if (failMax) throw StateError('Id/Account required');
    return MaxSendableResult(
      chain: 'solana',
      max: Amount(BigInt.from(15725120), 9),
      balance: Amount(BigInt.from(16621000), 9),
      fee: Amount(BigInt.from(5000), 9),
    );
  }
}

class _Store extends BalancesStore {
  _Store(super.wallet);
  @override
  List<TokenHolding> get holdings => [
    TokenHolding(
      mint: 'flash-mint',
      symbol: 'FLASH',
      name: 'Flash',
      balance: BigInt.parse('20000123456789'),
      decimals: 9,
      uiBalance: 20000.123456789,
    ),
  ];
}

Future<_Wallet> _pumpSend(
  WidgetTester tester, {
  String? mint,
  int decimals = 9,
}) async {
  final wallet = _Wallet();
  final balances = _Store(wallet);
  addTearDown(wallet.dispose);
  addTearDown(balances.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<BalancesStore>.value(value: balances),
      ],
      child: MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SendScreen(
          mint: mint,
          symbol: mint == null ? 'SOL' : 'FLASH',
          decimals: decimals,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return wallet;
}

class _Wallet extends WalletService {
  final backend = _Backend();
  @override
  LibwalletBackend get libwallet => backend;
  @override
  WalletKind get kind => WalletKind.inapp;
  @override
  String? get publicKey => _source.address;
  @override
  UnifiedAccount? get currentAccount => _source;
  @override
  List<UnifiedAccount> get accounts => [_source, _recipient];
  @override
  BigInt get solBalance => BigInt.from(16621000);
  @override
  Future<void> refreshAccounts() async {}
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('SEND preserves an exact 18-decimal amount', (tester) async {
    final wallet = await _pumpSend(tester, mint: 'flash-mint', decimals: 18);
    await tester.enterText(
      find.byKey(const Key('send-recipient-input')),
      _recipient.address,
    );
    await tester.enterText(
      find.byKey(const Key('send-amount-input')),
      '0.123456789012345678',
    );
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    // Stop at simulation: the test must never authorize or broadcast.
    expect(wallet.backend.auditSimulatedAmount, isNotNull);
    expect(
      wallet.backend.auditSimulatedAmount!.value,
      BigInt.parse('123456789012345678'),
    );
  });

  test('SEND numeric parser rejects non-finite input', () {
    expect(parseAmount('NaN'), isNull);
    expect(parseAmount('Infinity'), isNull);
    expect(parseAmount('1e1000'), isNull);
  });
  testWidgets('invalid pasted amounts cannot crash SEND or reach simulation', (
    tester,
  ) async {
    final wallet = await _pumpSend(tester);
    await tester.enterText(
      find.byKey(const Key('send-recipient-input')),
      _recipient.address,
    );
    for (final value in ['NaN', 'Infinity', '1e1000', '0.0000000001']) {
      await tester.enterText(find.byKey(const Key('send-amount-input')), value);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(wallet.backend.auditSimulatedAmount, isNull, reason: value);
      expect(tester.takeException(), isNull, reason: value);
    }
  });
  testWidgets(
    'token SEND MAX fills exact loaded balance without another scan',
    (tester) async {
      final wallet = await _pumpSend(tester, mint: 'flash-mint');
      wallet.backend.failMax = true;
      await tester.tap(find.text('MAX'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '20000.123456789',
      );
      expect(wallet.backend.maxCalls, 0);
      expect(find.textContaining("Couldn't calculate"), findsNothing);
    },
  );

  testWidgets('late native MAX failure cannot overwrite edited input', (
    tester,
  ) async {
    final wallet = await _pumpSend(tester);
    final gate = Completer<void>();
    wallet.backend.maxGate = gate;
    wallet.backend.failMax = true;
    await tester.tap(find.text('MAX'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, '0.001');
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      '0.001',
    );
    expect(find.textContaining("Couldn't calculate"), findsNothing);
    expect(find.textContaining('Id/Account required'), findsNothing);
  });
  testWidgets(
    'SOL MAX can proceed to simulation without a Bitcoin spend plan',
    (tester) async {
      final wallet = await _pumpSend(tester);
      await tester.enterText(
        find.byKey(const Key('send-recipient-input')),
        _recipient.address,
      );
      await tester.tap(find.text('MAX'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(wallet.backend.auditSimulatedAmount?.value, BigInt.from(15725120));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('amount remains editable after choosing an internal recipient', (
    tester,
  ) async {
    final wallet = _Wallet();
    final balances = BalancesStore(wallet);
    addTearDown(wallet.dispose);
    addTearDown(balances.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletService>.value(value: wallet),
          ChangeNotifierProvider<BalancesStore>.value(value: balances),
        ],
        child: MaterialApp(
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SendScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choose an account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send-recipient-recipient')));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(
      tester.widget<TextField>(fields.first).controller!.text,
      _recipient.address,
    );
    final amount = find.byType(EditableText).last;
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'MAX')).width,
      lessThan(90),
    );
    await tester.tap(fields.last);
    await tester.pump();
    expect(
      wallet.backend.maxCalls,
      0,
      reason: 'Tapping the amount must not activate MAX',
    );
    expect(tester.widget<EditableText>(amount).focusNode.hasFocus, isTrue);
    tester.testTextInput.enterText('0.001');
    expect(tester.widget<TextField>(fields.last).controller!.text, '0.001');
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(wallet.backend.maxCalls, 1);
    expect(wallet.backend.recipient, _recipient.address);
    expect(
      tester.widget<TextField>(fields.last).controller!.text,
      '0.01572512',
    );
    expect(wallet.currentAccount, same(_source));
    wallet.backend.failMax = true;
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("Couldn't calculate the maximum"),
      findsOneWidget,
    );
    await tester.tap(fields.last);
    await tester.pump();
    expect(tester.widget<EditableText>(amount).focusNode.hasFocus, isTrue);
    tester.testTextInput.enterText('0.002');
    await tester.pump();
    expect(tester.widget<TextField>(fields.last).controller!.text, '0.002');
    expect(find.textContaining("Couldn't calculate the maximum"), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
