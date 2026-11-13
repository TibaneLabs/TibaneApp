import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType, Asset;
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/wallet_dashboard.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/jupiter_service.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

class _Backend extends LibwalletBackend {
  @override
  Network? get currentNetwork => Network(
    id: 'solana',
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
}

class _Wallet extends WalletService {
  final backend = _Backend();
  @override
  LibwalletBackend get libwallet => backend;
  @override
  List<Asset> get assets => const [];
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Balances extends BalancesStore {
  final double change;
  final int nativeUnits;
  @override
  List<TokenHolding> holdings;

  _Balances(super.wallet, this.change, this.nativeUnits, this.holdings);

  void replaceHoldings(List<TokenHolding> next) {
    holdings = next;
    notifyListeners();
  }

  @override
  TokenHolding? get nativeSolHolding => TokenHolding(
    mint: 'SOL',
    symbol: 'SOL',
    name: 'Solana',
    balance: BigInt.from(nativeUnits),
    decimals: 9,
    uiBalance: nativeUnits / 1e9,
    priceUsd: 100,
    valueUsd: nativeUnits / 1e9 * 100,
    priceChange24h: change,
  );
}

Future<_Balances> _pumpDashboard(
  WidgetTester tester, {
  double change = 0,
  int nativeUnits = 1000000000,
  List<TokenHolding> holdings = const [],
}) async {
  final wallet = _Wallet();
  final balances = _Balances(wallet, change, nativeUnits, holdings);
  final compliance = UkComplianceService();
  addTearDown(wallet.dispose);
  addTearDown(balances.dispose);
  addTearDown(compliance.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<BalancesStore>.value(value: balances),
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
  return balances;
}

TokenHolding _chiefPussy(int raw, {double? valueUsd}) => TokenHolding(
  mint: chiefPussyMint,
  symbol: 'ChiefPussy',
  name: 'Tibanne Thecat',
  balance: BigInt.from(raw),
  decimals: 6,
  uiBalance: raw / 1e6,
  valueUsd: valueUsd,
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('portfolio hides zero tokens and insignificant residuals', (
    tester,
  ) async {
    final balances = await _pumpDashboard(
      tester,
      nativeUnits: 0,
      holdings: [_chiefPussy(1000000, valueUsd: 0.02)],
    );
    final token = find.text('ChiefPussy');
    expect(token, findsOneWidget);

    balances.replaceHoldings([_chiefPussy(1, valueUsd: 0.00000002)]);
    await tester.pumpAndSettle();
    expect(token, findsNothing);
    expect(balances.holdings.single.balance, BigInt.one);

    balances.replaceHoldings([_chiefPussy(0)]);
    await tester.pumpAndSettle();
    expect(token, findsNothing);
    expect(find.text('SOL'), findsOneWidget);
  });

  testWidgets('tiny tokens with material or unknown USD value stay visible', (
    tester,
  ) async {
    final balances = await _pumpDashboard(
      tester,
      holdings: [_chiefPussy(1, valueUsd: 0.10)],
    );
    expect(find.text('ChiefPussy'), findsOneWidget);
    expect(find.text('<0.0001'), findsOneWidget);

    balances.replaceHoldings([_chiefPussy(1)]);
    await tester.pumpAndSettle();
    expect(find.text('ChiefPussy'), findsOneWidget);
    expect(find.text('<0.0001'), findsOneWidget);

    balances.replaceHoldings([_chiefPussy(100, valueUsd: 0)]);
    await tester.pumpAndSettle();
    expect(find.text('ChiefPussy'), findsOneWidget);
    expect(find.text('0.0001'), findsOneWidget);
  });

  for (final change in [-5.36, 10.0]) {
    for (final width in [320.0, 393.0]) {
      testWidgets(
        'whole PnL is 3 px left of SOL center at $width, change $change',
        (tester) async {
          tester.view.physicalSize = Size(width * 2, 1704);
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await _pumpDashboard(tester, change: change);
          final sol = find.text('1.0000 SOL');
          final pnl = find.byKey(const Key('wallet-pnl-content'));
          final pill = find.descendant(
            of: pnl,
            matching: find.byType(Container),
          );
          final amount = find.descendant(
            of: pnl,
            matching: find.textContaining(RegExp(r'^\$[0-9.,]+$')),
          );
          final percent = find.descendant(
            of: pnl,
            matching: find.textContaining(RegExp(r'^[+-][0-9.]+%$')),
          );
          final total = find.byKey(const Key('wallet-total-balance'));
          final totalText = tester.widget<Text>(total);
          expect(
            totalText.style!.fontSize,
            closeTo(
              Theme.of(
                    tester.element(total),
                  ).textTheme.displaySmall!.fontSize! *
                  1.38 *
                  1.15,
              0.001,
            ),
          );
          expect(
            tester.getTopLeft(sol).dy - tester.getBottomLeft(total).dy,
            closeTo(0, 0.01),
          );
          expect(sol, findsOneWidget);
          expect(amount, findsOneWidget);
          expect(percent, findsOneWidget);
          expect(find.descendant(of: pill, matching: amount), findsOneWidget);
          expect(find.descendant(of: pill, matching: percent), findsNothing);
          final amountStyle = tester.widget<Text>(amount).style!;
          expect(amountStyle.fontSize, 12);
          expect(amountStyle.fontWeight, FontWeight.w700);
          expect(
            amountStyle.fontFamily,
            GoogleFonts.dmSans(fontWeight: FontWeight.w700).fontFamily,
          );
          expect(tester.widget<Text>(percent).style!.fontSize, 11);
          expect(tester.widget<Text>(percent).style!.fontWeight, FontWeight.w800);
          expect(
            tester.getCenter(pnl).dx,
            closeTo(tester.getCenter(sol).dx - 3, 0.01),
          );
          expect(
            tester.getTopRight(pill).dx,
            lessThan(tester.getTopLeft(percent).dx),
          );
          expect(
            tester.getTopLeft(percent).dy,
            greaterThan(tester.getBottomLeft(sol).dy),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
