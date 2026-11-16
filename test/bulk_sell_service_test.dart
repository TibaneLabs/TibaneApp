import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:libwallet/src/api/swap_api.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/l10n.dart';
import 'package:tibaneapp/screens/bulk_sell_screen.dart';
import 'package:tibaneapp/screens/wallet/widgets/authorize_and_sign.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/rpc_service.dart';
import 'package:tibaneapp/services/wallet/bulk_sell_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/token_icon.dart';

const _account = (id: 'account', address: 'address', networkId: 'mainnet-id');
const _keys = [lw.SigningKey(id: 'key-id', key: 'fixture-key')];

TokenHolding _holding(String mint, int amount) => TokenHolding(
  mint: mint,
  symbol: mint,
  name: mint,
  balance: BigInt.from(amount),
  decimals: 6,
  uiBalance: amount / 1e6,
);

class _Holdings extends JupiterService {
  @override
  Future<List<TokenHolding>> fetchHoldings(
    String walletAddress, {
    String? excludeMint,
    bool reserveSolForFees = true,
  }) async {
    expect(walletAddress, _account.address);
    expect(reserveSolForFees, isFalse);
    return [
      _holding(wsolMint, 9000),
      _holding('a', 1000),
      _holding('b', 0),
      _holding('a', 25),
      _holding('c', 4200),
    ];
  }
}

class _Rpc extends RpcService {
  _Rpc() : super.real();

  @override
  Future<BigInt> getBalance(String address) async => BigInt.from(100000);

  @override
  Future<List<SolanaSignatureStatus>> getSignatureStatuses(
    List<String> signatures,
  ) async => [
    for (final signature in signatures)
      signature == 'signature-a'
          ? SolanaSignatureStatus.confirmed
          : SolanaSignatureStatus.failed,
  ];
}

class _Swap implements SwapApi {
  final prepared = <String, lw.SwapQuote>{};
  final submissions = <String>[];
  final unquotable = <String>{};
  final badAmount = <String>{};
  final ambiguous = <String>{};
  void Function()? afterExecute;

  @override
  Future<lw.SwapQuote> quote({
    required lw.SwapTokenRef tokenIn,
    required lw.SwapTokenRef tokenOut,
    required String amountIn,
    String? from,
    int? slippageBps,
    String? network,
    String? provider,
  }) async {
    expect(from, _account.id);
    expect(network, _account.networkId);
    expect(tokenOut.address, 'NATIVE');
    expect(tokenOut.decimals, 9);
    expect(slippageBps, 100);
    final mint = tokenIn.address;
    if (unquotable.contains(mint)) throw StateError('No route');
    return prepared[mint] = lw.SwapQuote(
      quoteId: mint,
      provider: 'okx_solana',
      chain: 'solana',
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      amountIn: lw.Amount(
        BigInt.parse(amountIn) +
            (badAmount.contains(mint) ? BigInt.one : BigInt.zero),
        tokenIn.decimals,
      ),
      amountOut: lw.Amount(BigInt.from(100200), 9),
      minAmountOut: lw.Amount(BigInt.from(99000), 9),
      networkFee: lw.Amount(BigInt.from(5100), 9),
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
  }

  @override
  Future<lw.SwapResult> execute({
    required String quoteId,
    required List<lw.SigningKey> keys,
    String? from,
    bool? mevProtection,
    bool? closeTokenAccount,
  }) async {
    expect(closeTokenAccount, isFalse);
    expect(keys, same(_keys));
    expect(from, _account.id);
    submissions.add(quoteId);
    afterExecute?.call();
    if (ambiguous.contains(quoteId)) throw StateError('Connection dropped');
    return lw.SwapResult(
      quoteId: quoteId,
      provider: 'okx_solana',
      chain: 'solana',
      hash: 'signature-$quoteId',
      url: '',
      quote: prepared[quoteId]!,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements lw.LibwalletClient {
  _Client(this.swap);
  @override
  final _Swap swap;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  String networkType = 'solana';
  bool testNet = false;
  @override
  String get accountId => _account.id;
  @override
  lw.Network get currentNetwork => lw.Network.fromJson({
    'Id': _account.networkId,
    'Type': networkType,
    'ChainId': 'mainnet',
    'TestNet': testNet,
    'Created': '2026-01-01T00:00:00Z',
    'Updated': '2026-01-01T00:00:00Z',
  });
}

class _Wallet extends WalletService {
  final _backend = _Backend();
  @override
  LibwalletBackend get libwallet => _backend;
  @override
  WalletKind get kind => WalletKind.inapp;
  @override
  bool get isConnected => true;
  @override
  String get publicKey => _account.address;

  @override
  void dispose() {
    _backend.dispose();
    super.dispose();
  }
}

class _Balances extends BalancesStore {
  _Balances(super.wallet);
  int refreshes = 0;
  @override
  void onTxCommitted(String? signature) => refreshes++;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  late _Swap swap;
  late BulkSellService service;
  setUp(() {
    swap = _Swap();
    service = BulkSellService(
      client: () async => _Client(swap),
      jupiter: _Holdings(),
      rpc: _Rpc(),
    );
  });
  tearDown(() => service.dispose());

  test('requires an in-app Solana mainnet account', () {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    expect(bulkSellAccountFor(wallet), _account);
    wallet._backend.testNet = true;
    expect(bulkSellAccountFor(wallet), isNull);
    wallet._backend.testNet = false;
    wallet._backend.networkType = 'evm';
    expect(bulkSellAccountFor(wallet), isNull);
  });

  test(
    'uses only positive SPL holdings and aggregates duplicate mints',
    () async {
      final holdings = await service.holdings(_account);
      expect(holdings.map((h) => h.mint), ['a', 'c']);
      expect(holdings.first.balance, BigInt.from(1025));
    },
  );

  test(
    'review sums exact minimums and execution reports partial success',
    () async {
      final review = await service.prepare(_account, [
        _holding('a', 10),
        _holding('c', 20),
        _holding('d', 30),
      ], isCurrent: () => true);
      expect(swap.submissions, isEmpty);
      expect(review.hasQuotes, isTrue);
      expect(review.minimum, BigInt.from(297000));
      expect(review.estimatedFees, BigInt.from(15300));
      swap.ambiguous.add('d');
      final outcomes = <String, BulkSellOutcome>{};
      await service.execute(
        review,
        _keys,
        canSubmit: () => true,
        isOpen: () => true,
        onUpdate: (mint, result) => outcomes[mint] = result,
      );
      expect(swap.submissions, ['a', 'c', 'd']);
      expect(outcomes['a']?.status, BulkSellStatus.sold);
      expect(outcomes['c']?.status, BulkSellStatus.failed);
      expect(outcomes['d']?.status, BulkSellStatus.pending);
    },
  );

  test('missing or mismatched quotes block the batch', () async {
    swap.unquotable.add('b');
    swap.badAmount.add('c');
    final review = await service.prepare(_account, [
      _holding('a', 10),
      _holding('b', 20),
      _holding('c', 30),
    ], isCurrent: () => true);
    expect(review.hasQuotes, isFalse);
    await service.execute(
      review,
      _keys,
      canSubmit: () => true,
      isOpen: () => true,
      onUpdate: (_, _) => fail('Blocked batch must not submit'),
    );
    expect(swap.submissions, isEmpty);
  });

  test('account change prevents any further submissions', () async {
    final review = await service.prepare(_account, [
      _holding('a', 10),
      _holding('c', 20),
    ], isCurrent: () => true);
    var current = true;
    swap.afterExecute = () => current = false;
    final outcomes = <String, BulkSellOutcome>{};
    await service.execute(
      review,
      _keys,
      canSubmit: () => current,
      isOpen: () => true,
      onUpdate: (mint, result) => outcomes[mint] = result,
    );
    expect(swap.submissions, ['a']);
    expect(outcomes['a']?.status, BulkSellStatus.sold);
    expect(outcomes.containsKey('c'), isFalse);
  });

  testWidgets('select and review two tokens, then authorize just once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wallet = _Wallet();
    final balances = _Balances(wallet);
    var authorizations = 0;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletService>.value(value: wallet),
          ChangeNotifierProvider<BalancesStore>.value(value: balances),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BulkSellScreen.testing(
            service: service,
            authorize: (_) async {
              authorizations++;
              return const BatchAuth(_keys);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(3));
    final selectAll = find.byKey(const ValueKey('bulk-sell-select-all'));
    final token = find.byKey(const ValueKey('a'));
    final otherToken = find.byKey(const ValueKey('c'));
    Finder checkboxIn(Finder row) =>
        find.descendant(of: row, matching: find.byType(Checkbox));
    bool? checked(Finder row) => tester.widget<Checkbox>(checkboxIn(row)).value;
    expect(find.text('Select all'), findsOneWidget);
    expect(
      tester.getTopLeft(selectAll).dy,
      lessThan(tester.getTopLeft(token).dy),
    );
    for (final row in [selectAll, token, otherToken]) {
      expect(
        tester.widget<Checkbox>(checkboxIn(row)).shape,
        isA<CircleBorder>(),
      );
      final scale = tester.widget<Transform>(
        find.descendant(of: row, matching: find.byType(Transform)).first,
      );
      expect(scale.transform.entry(0, 0), 1.15);
      expect(checked(row), isFalse);
    }
    expect(
      tester
          .widget<TokenIcon>(
            find.descendant(of: token, matching: find.byType(TokenIcon)),
          )
          .size,
      44.85,
    );
    expect(tester.widget<Text>(find.text('a')).style?.fontSize, 16.1);
    expect(tester.widget<Text>(find.text('0.001025')).style?.fontSize, 18.4);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Cancel'))
          .style
          ?.backgroundColor
          ?.resolve({}),
      TibaneColors.surface,
    );
    final bulkSell = find.widgetWithText(FilledButton, 'Bulk Sell');
    for (final button in [
      bulkSell,
      find.widgetWithText(FilledButton, 'Cancel'),
    ]) {
      final fontSize = Theme.of(
        tester.element(button),
      ).textTheme.labelLarge!.fontSize!;
      expect(
        tester
            .widget<FilledButton>(button)
            .style
            ?.textStyle
            ?.resolve({})
            ?.fontSize,
        closeTo(fontSize * 1.2, 0.001),
      );
    }
    await tester.tap(token);
    await tester.pumpAndSettle();
    expect(checked(selectAll), isNull);
    await tester.tap(checkboxIn(selectAll));
    await tester.pumpAndSettle();
    expect(checked(selectAll), isTrue);
    expect(checked(token), isTrue);
    expect(checked(otherToken), isTrue);
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    expect(checked(selectAll), isFalse);
    expect(checked(token), isFalse);
    expect(checked(otherToken), isFalse);
    expect(tester.widget<FilledButton>(bulkSell).onPressed, isNull);
    await tester.tap(checkboxIn(selectAll));
    await tester.pumpAndSettle();
    await tester.tap(bulkSell);
    await tester.pumpAndSettle();
    expect(find.text('Review bulk sell'), findsOneWidget);
    final total = find.text('0.000198 SOL');
    expect(total, findsOneWidget);
    final totalStyle = tester.widget<Text>(total).style!;
    final headline = Theme.of(tester.element(total)).textTheme.headlineSmall!;
    expect(totalStyle.fontSize, closeTo(headline.fontSize! * 1.15, 0.001));
    expect(totalStyle.fontWeight, FontWeight.w500);
    expect(find.text('Minimum total in SOL'), findsNothing);
    expect(find.textContaining('Network fees:'), findsOneWidget);
    expect(find.textContaining('Each token is sold'), findsNothing);
    expect(authorizations, 0);
    expect(swap.submissions, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(authorizations, 1);
    expect(swap.submissions, ['a', 'c']);
    expect(find.textContaining('Sold'), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);
    expect(balances.refreshes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    balances.dispose();
    wallet.dispose();
  });
}
