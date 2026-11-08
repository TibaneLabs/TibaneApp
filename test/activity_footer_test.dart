import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/main.dart';
import 'package:tibaneapp/models/transaction_activity.dart';
import 'package:tibaneapp/screens/wallet/activity_screen.dart';
import 'package:tibaneapp/services/balances_store.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _owner = '11111111111111111111111111111111';

Network _network({
  String chain = 'mainnet',
  NetworkType type = NetworkType.solana,
}) => Network(
  id: 'fixture-$chain',
  type: type,
  chainId: chain,
  name: 'Solana',
  rpc: '',
  currencySymbol: 'SOL',
  currencyDecimals: 9,
  blockExplorer: 'https://explorer.solana.com',
  resolvedBlockExplorer: type == NetworkType.evm ? 'https://etherscan.io' : '',
  testNet: chain == 'devnet',
  priority: 0,
  created: DateTime.utc(2026),
  updated: DateTime.utc(2026),
);

class _Backend extends LibwalletBackend {
  @override
  Network get currentNetwork => _network();
  @override
  Future<bool> needsBiometricMigration() async => false;
}

class _Wallet extends WalletService {
  final backend = _Backend();
  @override
  LibwalletBackend get libwallet => backend;
  @override
  bool get dataReady => true;
  @override
  String get publicKey => _owner;
  @override
  Future<void> reportLifecycle(String status) async {}
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

class _Store extends BalancesStore {
  _Store(super.wallet);
  int refreshes = 0;
  @override
  bool get loadingTxs => false;
  @override
  Future<void> refreshHistory() async {
    refreshes++;
  }

  @override
  List<Transaction> get transactions => [
    for (var n = 0; n < 12; n++)
      Transaction(
        id: 'row-$n',
        type: 'transfer',
        asset: 'solana.mainnet.NATIVE',
        from: _owner,
        to: 'public-recipient',
        gas: 0,
        nonce: 0,
        hash: 'public-hash-$n',
        amount: Amount(BigInt.from(10000000), 9),
        created: DateTime.utc(2026, 11, 8, 12, n),
      ),
  ];
  @override
  TransactionActivity? activityFor(Transaction tx) => TransactionActivity(
    kind: ActivityKind.received,
    failed: false,
    fee: BigInt.from(5000),
    sender: 'public-sender',
    recipient: _owner,
    changes: [
      ActivityTokenChange(
        mint: wsolMint,
        amount: BigInt.from(10000000),
        decimals: 9,
        symbol: 'SOL',
      ),
    ],
  );
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    if (const bool.fromEnvironment('CAPTURE_ACTIVITY')) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => '/tmp',
          );
      TibaneTheme.darkTheme;
      await GoogleFonts.pendingFonts();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final channel in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });

  test(
    'View All uses the correct account and Solana cluster; never sends EVM addresses to Solscan',
    () {
      expect(
        activityExplorerUrl(_owner, _network()),
        'https://solscan.io/account/$_owner',
      );
      expect(
        activityExplorerUrl(_owner, _network(chain: 'devnet')),
        'https://solscan.io/account/$_owner?cluster=devnet',
      );
      expect(
        activityExplorerUrl(
          '0x123',
          _network(chain: '1', type: NetworkType.evm),
        ),
        'https://etherscan.io/address/0x123',
      );
      expect(activityExplorerUrl(null, _network()), isNull);
      expect(
        activityExplorerUrl(
          _owner,
          _network(chain: 'devnet', type: NetworkType.evm),
          externalSolana: true,
        ),
        'https://solscan.io/account/$_owner',
        reason: 'CatCard and MWA must ignore the inactive in-app network',
      );
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'Activity footer opens a nine-row list and View All in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(786, 1704);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final wallet = _Wallet();
        final store = _Store(wallet);
        final compliance = UkComplianceService();
        final urls = <String>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch') {
            urls.add((call.arguments as Map)['url'] as String);
          }
          return true;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
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
            child: RepaintBoundary(
              key: const Key('activity-preview'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: locale,
                theme: TibaneTheme.darkTheme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const TibaneShell(forceSeeker: false),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = await AppLocalizations.delegate.load(locale);
        final footer = find.byType(BottomNavigationBar);
        expect(tester.widget<BottomNavigationBar>(footer).items, hasLength(4));
        expect(store.refreshes, 0);
        await tester.tap(
          find.descendant(
            of: footer,
            matching: find.text(l10n.dashboardTabActivity),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ActivityScreen), findsOneWidget);
        expect(store.refreshes, 1);
        expect(find.byKey(const Key('wallet-activity-tabs')), findsNothing);
        if (locale.languageCode == 'en' &&
            const bool.fromEnvironment('CAPTURE_ACTIVITY')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('activity-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/tibane-activity-footer.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        final viewAll = find.byKey(const Key('activity-view-all'));
        await tester.scrollUntilVisible(
          viewAll,
          240,
          scrollable: find
              .descendant(
                of: find.byType(ActivityScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        if (locale.languageCode == 'en' &&
            const bool.fromEnvironment('CAPTURE_ACTIVITY')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('activity-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/tibane-activity-footer-bottom.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(
          find.byKey(const Key('activity-transaction-row-8')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('activity-transaction-row-9')),
          findsNothing,
        );
        await tester.tap(viewAll);
        await tester.pumpAndSettle();
        expect(urls, ['https://solscan.io/account/$_owner']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
