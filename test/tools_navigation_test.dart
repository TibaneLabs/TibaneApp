import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/models/staking_pool.dart';
import 'package:tibaneapp/screens/incinerator_screen.dart';
import 'package:tibaneapp/screens/staking/staking_pools_screen.dart';
import 'package:tibaneapp/screens/token_favorites_screen.dart';
import 'package:tibaneapp/screens/tools_screen.dart';
import 'package:tibaneapp/services/chiefstaker_api.dart';
import 'package:tibaneapp/services/favorites_service.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _solana = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'solana',
  address: 'public-solana-address',
  label: 'Solana',
  walletId: 'wallet-sol',
  accountId: 'solana',
);
const _ethereum = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'ethereum',
  address: '0xPublicEthereumAddress',
  label: 'Ethereum',
  walletId: 'wallet-eth',
  accountId: 'ethereum',
);

class _Backend extends LibwalletBackend {
  final searches = <String>[];
  @override
  Future<List<TokenSearchResult>> searchCuratedTokens(
    String query, {
    String? network,
    int limit = 20,
  }) async {
    searches.add(query);
    return [];
  }
}

class _Wallet extends WalletService {
  final backend = _Backend();
  UnifiedAccount? current;
  List<UnifiedAccount> entries = [];
  final switches = <UnifiedAccount>[];
  bool failSwitch = false;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  bool get isConnected => false;
  @override
  UnifiedAccount? get currentAccount => current;
  @override
  List<UnifiedAccount> get accounts => entries;
  @override
  bool get solanaFeaturesEnabled => solanaOnlyFeaturesEnabled(current);
  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount account, {
    String? networkId,
  }) async {
    switches.add(account);
    if (failSwitch) return false;
    current = account;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Compliance extends UkComplianceService {
  bool uk = false;
  @override
  bool get isUk => uk;
  void setRegion(bool value) {
    uk = value;
    notifyListeners();
  }
}

class _Pools extends ChiefStakerApi {
  _Pools() : super.real();
  int loads = 0;
  @override
  Future<List<StakingPool>> listPools({int perPage = 100}) async {
    loads++;
    return [];
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester,
  _Wallet wallet, {
  _Compliance? compliance,
  Locale locale = const Locale('en'),
  Size size = const Size(393, 852),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final region = compliance ?? _Compliance();
  final favorites = FavoritesService();
  addTearDown(region.dispose);
  addTearDown(favorites.dispose);
  addTearDown(wallet.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<UkComplianceService>.value(value: region),
        ChangeNotifierProvider<FavoritesService>.value(value: favorites),
      ],
      child: MaterialApp(
        locale: locale,
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ToolsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(ToolsScreen)));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 120);
  } else {
    await tester.ensureVisible(target);
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => ChiefStakerApi.testInstance = _Pools());
  tearDown(() => ChiefStakerApi.testInstance = null);

  for (final locale in AppLocalizations.supportedLocales) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      testWidgets('Tools lists all three translated features: $locale $size', (
        tester,
      ) async {
        final l10n = await _pump(tester, _Wallet(), locale: locale, size: size);
        for (final (key, title) in [
          ('tools-stake', l10n.homeStakeCardTitle),
          ('tools-incinerator', l10n.incineratorTitle),
          ('tools-search', l10n.homeTokenInfoTitle),
        ]) {
          final card = find.byKey(Key(key));
          await tester.ensureVisible(card);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: card, matching: find.text(title)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('regional gate hides Stake without hiding other tools', (
    tester,
  ) async {
    final region = _Compliance()..uk = true;
    await _pump(tester, _Wallet(), compliance: region);
    expect(find.byKey(const Key('tools-stake')), findsNothing);
    expect(find.byKey(const Key('tools-incinerator')), findsOneWidget);
    expect(find.byKey(const Key('tools-search')), findsOneWidget);
    expect((ChiefStakerApi.testInstance as _Pools).loads, 0);
    region.setRegion(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tools-stake')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (key, screen) in [
    ('tools-stake', StakingPoolsScreen),
    ('tools-incinerator', IncineratorScreen),
  ]) {
    testWidgets('$key switches an EVM context to Solana before opening', (
      tester,
    ) async {
      final wallet = _Wallet()
        ..current = _ethereum
        ..entries = [_ethereum, _solana];
      await _pump(tester, wallet);
      await _tap(tester, key);
      expect(wallet.switches, [_solana]);
      expect(wallet.current, _solana);
      expect(find.byType(screen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ToolsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$key stays in Tools when no Solana account is available', (
      tester,
    ) async {
      final wallet = _Wallet()
        ..current = _ethereum
        ..entries = [_ethereum];
      final l10n = await _pump(tester, wallet);
      await _tap(tester, key);
      expect(find.byType(screen), findsNothing);
      expect(find.text(l10n.homeSolanaAccountUnavailable), findsOneWidget);
      expect(wallet.switches, isEmpty);
    });
  }

  testWidgets('Search opens and searches without changing the active account', (
    tester,
  ) async {
    final wallet = _Wallet()
      ..current = _ethereum
      ..entries = [_ethereum];
    await _pump(tester, wallet, compliance: _Compliance()..uk = true);
    await _tap(tester, 'tools-search');
    expect(find.byType(TokenFavoritesScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'SOL');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(wallet.backend.searches, ['SOL']);
    expect(wallet.current, _ethereum);
    expect(wallet.switches, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
