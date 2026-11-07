import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:libwallet/src/api/transaction_api.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/models/transaction_activity.dart';
import 'package:tibaneapp/screens/wallet/wallet_dashboard.dart';
import 'package:tibaneapp/screens/wallet/transaction_details_screen.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/transaction_activity_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/tx_success.dart';

const _address = '11111111111111111111111111111111';

class _Transport implements lw.Transport {
  final calls = <String>[];
  int backfills = 0;
  bool hasHistory = true;
  bool fail = false;

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add('$verb $path');
    if (path == 'Transaction:backfill') {
      backfills++;
      if (fail) throw StateError('RPC unavailable');
      return {'started': true, 'count': hasHistory ? 1 : 0};
    }
    if (path == 'Transaction') {
      return backfills == 0 || !hasHistory
          ? <Object>[]
          : [
              {
                'Id': 'fixture-tx',
                'Type': 'other',
                'Asset': 'solana.mainnet.NATIVE',
                'From': _address,
                'To': '',
                'Hash': 'fixture-swap-signature',
                'Created': '2026-10-20T12:00:00Z',
                'Amount': {'v': '1000000', 'e': 9},
              },
            ];
    }
    throw StateError('Unexpected request: $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements lw.LibwalletClient {
  _Client(this.transport);
  final _Transport transport;
  @override
  TransactionApi get transactions => TransactionApi(transport);
  @override
  Stream<lw.TxHistoryUpdatedEvent> get txHistoryUpdates => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  final transport = _Transport();
  @override
  String? get accountId => 'fixture-account';
  @override
  Future<lw.LibwalletClient> ensureClient() async => _Client(transport);
}

class _Wallet extends WalletService {
  final backend = _Backend();
  @override
  LibwalletBackend get libwallet => backend;
  @override
  String? get publicKey => _address;
  @override
  WalletKind get kind => WalletKind.inapp;
  @override
  List<lw.Asset> get assets => const [];
  @override
  Future<void> discoverHoldings() async {}
  @override
  Future<void> refreshBalances() async {}
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Jupiter extends JupiterService {
  @override
  Future<List<TokenHolding>> fetchHoldings(
    String owner, {
    String? excludeMint,
    bool reserveSolForFees = true,
  }) async => const [];
}

class _ActivityService extends TransactionActivityService {
  _ActivityService({this.swap = false, this.received = false});
  final bool swap;
  final bool received;
  @override
  Future<TransactionActivity?> loadSolana(
    String signature,
    String owner,
  ) async => TransactionActivity(
    kind: swap
        ? ActivityKind.swap
        : received
        ? ActivityKind.received
        : ActivityKind.sent,
    changes: [
      ActivityTokenChange(
        mint: wsolMint,
        amount: BigInt.from(received ? 10000000 : -2500000),
        decimals: 9,
        symbol: 'SOL',
      ),
      if (swap)
        ActivityTokenChange(
          mint: 'token',
          amount: BigInt.from(994802149),
          decimals: 6,
          symbol: 'TEST',
        ),
    ],
    failed: false,
    fee: BigInt.from(5000),
    sender: owner,
    recipient: swap ? owner : 'recipient',
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test(
    'history refresh uses official backfill then reads rows without events',
    () async {
      final wallet = _Wallet();
      final store = BalancesStore(
        wallet,
        jupiter: _Jupiter(),
        activityService: _ActivityService(),
      );
      addTearDown(wallet.dispose);
      addTearDown(store.dispose);
      await store.refreshHistory();
      expect(store.loadingTxs, false);
      expect(store.transactions.single.hash, 'fixture-swap-signature');
      expect(wallet.backend.transport.calls.first, 'POST Transaction:backfill');
      expect(wallet.backend.transport.calls, contains('GET Transaction'));
      expect(
        wallet.backend.transport.calls.any((c) => c.contains('setCurrent')),
        false,
      );
      wallet.backend.transport.fail = true;
      await store.refreshHistory();
      expect(store.loadingTxs, false);
      expect(store.transactions.single.hash, 'fixture-swap-signature');
    },
  );

  test('empty history completes loading', () async {
    final wallet = _Wallet();
    wallet.backend.transport.hasHistory = false;
    final store = BalancesStore(
      wallet,
      jupiter: _Jupiter(),
      activityService: _ActivityService(received: true),
    );
    addTearDown(wallet.dispose);
    addTearDown(store.dispose);
    await store.refreshHistory();
    expect(store.loadingTxs, false);
    expect(store.transactions, isEmpty);
  });

  testWidgets('opening Activity fetches and renders history', (tester) async {
    final wallet = _Wallet();
    final store = BalancesStore(
      wallet,
      jupiter: _Jupiter(),
      activityService: _ActivityService(received: true),
    );
    final compliance = UkComplianceService();
    addTearDown(wallet.dispose);
    addTearDown(store.dispose);
    addTearDown(compliance.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletService>.value(value: wallet),
          ChangeNotifierProvider<BalancesStore>.value(value: store),
          ChangeNotifierProvider<UkComplianceService>.value(value: compliance),
        ],
        child: MaterialApp(
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: WalletDashboard()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(wallet.backend.transport.backfills, 0);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(wallet.backend.transport.backfills, greaterThan(0));
    expect(find.text('Received'), findsOneWidget);
    final row = find.byKey(const Key('activity-transaction-fixture-tx'));
    final content = find.descendant(of: row, matching: find.byType(Row)).first;
    expect(
      tester.getRect(find.text('+0.01 SOL')).right,
      closeTo(tester.getRect(content).right, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'swap opens internal details in ${locale.languageCode} at 320px',
      (tester) async {
        tester.view.physicalSize = const Size(640, 1704);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final wallet = _Wallet();
        final store = BalancesStore(
          wallet,
          jupiter: _Jupiter(),
          activityService: _ActivityService(swap: true),
        );
        final compliance = UkComplianceService();
        addTearDown(wallet.dispose);
        addTearDown(store.dispose);
        addTearDown(compliance.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<WalletService>.value(value: wallet),
              ChangeNotifierProvider<BalancesStore>.value(value: store),
              ChangeNotifierProvider<UkComplianceService>.value(
                value: compliance,
              ),
            ],
            child: MaterialApp(
              locale: locale,
              theme: TibaneTheme.darkTheme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: WalletDashboard()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = await AppLocalizations.delegate.load(locale);
        final tabs = find.byKey(const Key('wallet-activity-tabs'));
        final oldLabelStyle = DefaultTextStyle.of(
          tester.element(tabs),
        ).style.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
        final oldLabel = TextPainter(
          text: TextSpan(text: l10n.dashboardTabTokens, style: oldLabelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(tester.getSize(tabs).height, closeTo(oldLabel.height + 30, 0.3));
        oldLabel.dispose();
        expect(
          tester
              .widget<Text>(find.text(l10n.dashboardTabActivity))
              .style!
              .fontSize,
          closeTo(13 * 1.2, 0.01),
        );
        await tester.tap(find.text(l10n.dashboardTabActivity));
        await tester.pumpAndSettle();
        final row = find.byKey(const Key('activity-transaction-fixture-tx'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: row, matching: find.text(l10n.swapButton)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text(l10n.dashboardTxSent)),
          findsNothing,
        );
        expect(find.text('-0.0025 SOL'), findsOneWidget);
        expect(find.text('+994.8021 TEST'), findsOneWidget);
        final title = find.descendant(
          of: row,
          matching: find.text(l10n.swapButton),
        );
        expect(
          tester.widget<Text>(title).style!.fontSize,
          closeTo(13 * 1.15, 0.01),
        );
        final content = find
            .descendant(of: row, matching: find.byType(Row))
            .first;
        expect(
          tester.getRect(find.text('-0.0025 SOL')).right,
          closeTo(tester.getRect(content).right, 0.01),
        );
        expect(
          tester.getRect(find.text('+994.8021 TEST')).right,
          closeTo(tester.getRect(content).right, 0.01),
        );
        final icon = tester.widget<Container>(
          find.byKey(const Key('activity-swap-icon-fixture-tx')),
        );
        expect((icon.decoration as BoxDecoration).shape, BoxShape.circle);
        expect(
          (icon.decoration as BoxDecoration).color,
          TibaneColors.orange.withValues(alpha: 0.1),
        );
        expect(icon.constraints!.maxWidth, 32);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(TransactionDetailsScreen), findsOneWidget);
        expect(find.text(l10n.activityDetailsTitle), findsOneWidget);
        expect(find.text(l10n.activitySender), findsOneWidget);
        expect(find.text(l10n.activityRecipient), findsOneWidget);
        expect(find.text(_address), findsNWidgets(2));
        expect(find.text('-0.0025 SOL'), findsOneWidget);
        expect(find.text('+994.802149 TEST'), findsOneWidget);
        final link = find.text(l10n.viewOnExplorerNamed('Solscan'));
        await tester.scrollUntilVisible(
          link,
          120,
          scrollable: find
              .descendant(
                of: find.byType(TransactionDetailsScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(link, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'Solana always uses Solscan even with a different configured explorer',
    () {
      final network = lw.Network(
        id: 'solana',
        type: lw.NetworkType.solana,
        chainId: 'mainnet',
        name: 'Solana',
        rpc: '',
        currencySymbol: 'SOL',
        currencyDecimals: 9,
        blockExplorer: 'https://explorer.solana.com',
        testNet: false,
        priority: 0,
        created: DateTime.utc(2026),
        updated: DateTime.utc(2026),
      );
      expect(
        explorerTxUrl(network, 'fixture-hash'),
        'https://solscan.io/tx/fixture-hash',
      );
    },
  );
}
