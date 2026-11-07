import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:libwallet/src/api/swap_api.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/swap_screen.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/gradient_button.dart';
import 'package:tibaneapp/widgets/tibane_card.dart';

final _network = lw.Network(
  id: 'solana',
  type: lw.NetworkType.solana,
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

class _Transport implements lw.Transport {
  BigInt maxAmount = BigInt.from(3024662);
  int? maxDecimals;
  bool failMax = false;
  String maxStatus = '';
  Map<String, dynamic>? maxParams;
  Map<String, dynamic>? quoteParams;
  lw.SwapError? quoteError;
  Completer<void>? maxGate;
  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    if (path == 'Swap:availability') {
      return {'available': true, 'network': 'solana.mainnet'};
    }
    if (path == 'Swap:maxSpendable') {
      maxParams = params;
      await maxGate?.future;
      if (failMax) throw StateError('MAX RPC unavailable');
      final attempts =
          await request('Swap:quotes', verb, {
                ...?params,
                'amountIn': maxAmount.toString(),
              })
              as Map;
      final quote = Map<String, dynamic>.from(
        attempts['attempts'][0]['quote'] as Map,
      );
      quote['status'] = maxStatus;
      if (maxDecimals != null) quote['amountIn']['e'] = maxDecimals;
      quote['statusMessage'] = maxStatus.isEmpty
          ? ''
          : 'Not enough balance for fees';
      return quote;
    }
    if (path == 'Swap:quotes') {
      quoteParams = params;
      if (quoteError case final error?) {
        return {
          'attempts': [
            {
              'provider': 'okx_solana',
              'providerLabel': 'OKX',
              'error': {'code': error.code, 'message': error.message},
            },
          ],
        };
      }
      return {
        'attempts': [
          {
            'provider': 'okx_solana',
            'providerLabel': 'OKX',
            'quote': {
              'quoteId': 'offline-quote',
              'provider': 'okx_solana',
              'providerLabel': 'OKX',
              'chain': 'solana',
              'tokenIn': params!['tokenIn'],
              'tokenOut': params['tokenOut'],
              'amountIn': {
                'v': params['amountIn'],
                'e': params['tokenIn']['decimals'],
              },
              'amountOut': {'v': '658560678', 'e': 6},
              'minAmountOut': {'v': '650000000', 'e': 6},
              'feeBps': 50,
              'priceImpact': 0.01,
              'networkFee': {'v': '5000', 'e': 9},
              'route': [
                {'venue': 'Raydium'},
              ],
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 2))
                  .toIso8601String(),
            },
          },
        ],
      };
    }
    throw StateError(
      'Unexpected call $path: no signing or broadcasting is permitted',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements lw.LibwalletClient {
  final transport = _Transport();
  @override
  late final SwapApi swap = SwapApi(transport);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  final client = _Client();
  @override
  lw.Network? get currentNetwork => _network;
  @override
  Future<lw.Network?> refreshCurrentNetwork() async => _network;
  @override
  Future<lw.LibwalletClient> ensureClient() async => client;
  @override
  String? get accountId => 'fixture-solana-account';
}

class _Wallet extends WalletService {
  String activeAddress = '11111111111111111111111111111111';
  final backend = _Backend();
  final BigInt balance;
  _Wallet(this.balance);
  @override
  LibwalletBackend get libwallet => backend;
  @override
  WalletKind get kind => WalletKind.inapp;
  @override
  bool get isConnected => true;
  @override
  String? get publicKey => activeAddress;
  @override
  BigInt get solBalance => balance;
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Jupiter extends JupiterService {
  final BigInt lamports;
  final int tokenUnits;
  bool? reserved;
  _Jupiter(this.lamports, {this.tokenUnits = 1000000000});
  @override
  Future<List<TokenHolding>> fetchHoldings(
    String walletAddress, {
    String? excludeMint,
    bool reserveSolForFees = true,
  }) async {
    reserved = reserveSolForFees;
    final balance = reserveSolForFees
        ? (lamports > BigInt.from(10000000)
              ? lamports - BigInt.from(10000000)
              : BigInt.zero)
        : lamports;
    return [
      if (!reserveSolForFees || balance > BigInt.zero)
        TokenHolding(
          mint: wsolMint,
          symbol: 'SOL',
          name: 'Solana',
          balance: balance,
          decimals: 9,
          uiBalance: balance.toDouble() / 1e9,
        ),
      TokenHolding(
        mint: 'flash-mint',
        symbol: 'FLASH',
        name: 'Flash',
        balance: BigInt.from(tokenUnits),
        decimals: 6,
        uiBalance: tokenUnits / 1e6,
      ),
    ];
  }
}

Future<_Wallet> _pump(
  WidgetTester tester, {
  required int lamports,
  String input = wsolMint,
  Locale locale = const Locale('en'),
  int tokenUnits = 1000000000,
}) async {
  final wallet = _Wallet(BigInt.from(lamports));
  final jupiter = _Jupiter(wallet.balance, tokenUnits: tokenUnits);
  final compliance = UkComplianceService();
  addTearDown(wallet.dispose);
  addTearDown(jupiter.dispose);
  addTearDown(compliance.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<UkComplianceService>.value(value: compliance),
      ],
      child: MaterialApp(
        locale: locale,
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(title: const Text('Swap')),
          body: SwapScreen(initialInputMint: input, jupiter: jupiter),
          bottomNavigationBar: const SizedBox(key: Key('footer'), height: 88),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(jupiter.reserved, false);
  return wallet;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('account change discards the previous swap quote', (
    tester,
  ) async {
    final wallet = await _pump(tester, lamports: 5959822);
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    final oldQuote = wallet.backend.client.transport.quoteParams;
    expect(oldQuote, isNotNull);
    wallet.activeAddress = 'HSYatVptUXtn4f5JeDBzRhceG5LoMnsL4CizfFjxS83y';
    wallet.notifyListeners();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('swap-submit')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(wallet.backend.client.transport.quoteParams, same(oldQuote));
    expect(
      tester
          .widget<GradientButton>(find.byKey(const Key('swap-submit')))
          .onPressed,
      isNull,
      reason: 'A new account must request and review its own quote',
    );
  });
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    testWidgets('quote rejection is short and localized in $language', (
      tester,
    ) async {
      final wallet = await _pump(
        tester,
        lamports: 9583000,
        input: 'flash-mint',
        locale: Locale(language),
      );
      wallet.backend.client.transport.quoteError = const lw.SwapError(
        code: 'provider_unavailable',
        message:
            'env error: rest Crypto/Okx:quote error: OKX API error 51006 '
            'on GET /api/v6/dex/aggregator/quote: Input value is too low. '
            'Please check the token decimals or token value.',
      );
      await tester.tap(find.byKey(const Key('swap-percent-100')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(SwapScreen)));
      expect(find.text(l10n.walletErrorSwapQuoteUnavailable), findsOneWidget);
      expect(find.textContaining('51006'), findsNothing);
      expect(find.textContaining('env error'), findsNothing);
      expect(find.textContaining('/api/v6/'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('swap-submit')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      final button = tester.widget<GradientButton>(
        find.byKey(const Key('swap-submit')),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('MAX keeps exact fee-adjusted SOL amount without rounding up', (
    tester,
  ) async {
    final wallet = await _pump(tester, lamports: 5959822);
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      '0.003024662',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('swap-submit')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GradientButton>(find.byKey(const Key('swap-submit')))
          .onPressed,
      isNotNull,
    );
    expect(
      wallet.backend.client.transport.maxParams!['from'],
      'fixture-solana-account',
    );
    expect(wallet.backend.client.transport.maxParams!['slippageBps'], 100);
  });

  testWidgets('MAX does not fall back to the full SOL balance on RPC failure', (
    tester,
  ) async {
    final wallet = await _pump(tester, lamports: 5959822);
    wallet.backend.client.transport.failMax = true;
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      isEmpty,
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(SwapScreen)));
    await tester.scrollUntilVisible(
      find.text(l10n.swapMaxAmountUnavailable),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(l10n.swapMaxAmountUnavailable), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MAX explains when balance cannot cover fees', (tester) async {
    final wallet = await _pump(tester, lamports: 5000);
    wallet.backend.client.transport.maxStatus = 'balance_too_small';
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.scrollUntilVisible(
      find.text("You don't have enough balance to cover this transaction."),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text("You don't have enough balance to cover this transaction."),
      findsOneWidget,
    );
  });

  testWidgets('SPL MAX uses the full exact token balance', (tester) async {
    final wallet = await _pump(tester, lamports: 5959822, input: 'flash-mint');
    wallet.backend.client.transport.maxAmount = BigInt.from(1000000000);
    wallet.backend.client.transport.failMax = true;
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      '1000',
    );
    expect(wallet.backend.client.transport.maxParams, isNull);
  });

  testWidgets('SPL MAX preserves six fractional digits through quote request', (
    tester,
  ) async {
    final wallet = await _pump(
      tester,
      lamports: 9583000,
      input: 'flash-mint',
      tokenUnits: 70645495481,
    );
    await tester.tap(find.text('MAX'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      '70645.495481',
    );
    final params = wallet.backend.client.transport.quoteParams!;
    expect(params['amountIn'], '70645495481');
    expect(params['tokenIn']['address'], 'flash-mint');
    expect(params['tokenIn']['decimals'], 6);
    expect(wallet.backend.client.transport.maxParams, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native MAX accepts a normalized Amount exponent', (
    tester,
  ) async {
    final wallet = await _pump(tester, lamports: 5959822);
    wallet.backend.client.transport.maxAmount = BigInt.from(3);
    wallet.backend.client.transport.maxDecimals = 3;
    await tester.tap(find.text('MAX'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      '0.003',
    );
  });

  testWidgets('late MAX response does not overwrite a newer percentage', (
    tester,
  ) async {
    final wallet = await _pump(tester, lamports: 5959822);
    final gate = Completer<void>();
    wallet.backend.client.transport.maxGate = gate;
    final size = tester.getSize(find.byKey(const Key('swap-percent-100')));
    await tester.tap(find.text('MAX'));
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('swap-percent-100'))), size);
    await tester.tap(find.text('25%'));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('swap-amount-input')))
          .controller!
          .text,
      '0.001489955',
    );
  });
  for (final balance in [0, 5000000, 10000000, 16621000]) {
    testWidgets('SOL remains selectable with $balance lamports', (
      tester,
    ) async {
      await _pump(tester, lamports: balance);
      expect(
        find.descendant(
          of: find.byKey(const Key('swap-input-selector')),
          matching: find.text('SOL'),
        ),
        findsOneWidget,
      );
      expect(find.text('ChiefPussy'), findsOneWidget);
      await tester.tap(find.byKey(const Key('swap-input-selector')));
      await tester.pumpAndSettle();
      expect(find.text('Solana'), findsOneWidget);
      expect(find.text('FLASH'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(393, 852),
    const Size(375, 667),
    const Size(320, 568),
  ]) {
    for (final input in [wsolMint, 'flash-mint']) {
      testWidgets('fees and button layout at $size with $input', (
        tester,
      ) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pump(tester, lamports: 10000000, input: input);
        expect(
          tester.widget<ListView>(find.byType(ListView).first).padding,
          const EdgeInsets.fromLTRB(16, 4, 16, 16),
        );
        await tester.enterText(
          find.byKey(const Key('swap-amount-input')),
          '0.001',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        final button = find.byKey(const Key('swap-submit'));
        await tester.scrollUntilVisible(
          button,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<GradientButton>(button).onPressed, isNotNull);
        expect(
          find.ancestor(of: button, matching: find.byType(ListView)),
          findsOneWidget,
        );
        final footerTop = tester.getTopLeft(find.byKey(const Key('footer'))).dy;
        expect(tester.getBottomLeft(button).dy, lessThan(footerTop));
        final slippage = find.byKey(const Key('swap-slippage'));
        expect(
          tester.getTopLeft(button).dy - tester.getBottomLeft(slippage).dy,
          closeTo(8, 0.01),
        );
        final toggle = find.byKey(const Key('swap-fees-toggle'));
        await tester.scrollUntilVisible(
          toggle,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Fees'), findsOneWidget);
        final fees = find.byKey(const Key('swap-fees-details'));
        expect(tester.getSize(fees).height, 50);
        expect(
          tester.widget<Padding>(slippage).padding,
          const EdgeInsets.only(bottom: 4),
        );
        expect(
          tester.widget<Text>(find.text('Fees')).style!.fontSize,
          11 * 1.15,
        );
        expect(
          find.ancestor(of: toggle, matching: find.byType(TibaneCard)),
          findsNothing,
        );
        expect(find.text('Provider'), findsNothing);
        await tester.tap(find.text('Fees'));
        await tester.pumpAndSettle();
        expect(find.text('Provider'), findsNothing);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Provider'), findsOneWidget);
        expect(find.text('Route'), findsOneWidget);
        await tester.scrollUntilVisible(
          button,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.getBottomLeft(button).dy, lessThan(footerTop));
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          toggle,
          -120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Provider'), findsNothing);
      });
    }
  }
}
