import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType, Asset;
import 'package:provider/provider.dart';
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
  _Balances(super.wallet, this.change);
  @override
  TokenHolding? get nativeSolHolding => TokenHolding(
    mint: 'SOL',
    symbol: 'SOL',
    name: 'Solana',
    balance: BigInt.from(1000000000),
    decimals: 9,
    uiBalance: 1,
    priceUsd: 100,
    valueUsd: 100,
    priceChange24h: change,
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final change in [-5.36, 10.0]) {
    for (final width in [320.0, 393.0]) {
      testWidgets(
        'whole PnL is 3 px left of SOL center at $width, change $change',
        (tester) async {
          tester.view.physicalSize = Size(width * 2, 1704);
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final wallet = _Wallet();
          final balances = _Balances(wallet, change);
          final compliance = UkComplianceService();
          addTearDown(wallet.dispose);
          addTearDown(balances.dispose);
          addTearDown(compliance.dispose);
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<WalletService>.value(value: wallet),
                ChangeNotifierProvider<BalancesStore>.value(value: balances),
                ChangeNotifierProvider<UkComplianceService>.value(
                  value: compliance,
                ),
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
          final sol = find.text('1.0000 SOL');
          final percent = find.textContaining(RegExp(r'^[+-][0-9.]+%$'));
          final pnl = find.byKey(const Key('wallet-pnl-content'));
          final total = find.byKey(const Key('wallet-total-balance'));
          final totalText = tester.widget<Text>(total);
          expect(
            totalText.style!.fontSize,
            closeTo(
              Theme.of(tester.element(total)).textTheme.displaySmall!.fontSize! *
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
          expect(percent, findsOneWidget);
          expect(
            tester.getCenter(pnl).dx,
            closeTo(tester.getCenter(sol).dx - 3, 0.01),
          );
          expect(
            tester.getCenter(percent).dx,
            lessThan(tester.getCenter(pnl).dx),
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
