import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/models/staking_pool.dart';
import 'package:tibaneapp/models/token_account.dart';
import 'package:tibaneapp/screens/fee_sharing_screen.dart';
import 'package:tibaneapp/screens/staking/staking_detail_screen.dart';
import 'package:tibaneapp/screens/token_detail_screen.dart';
import 'package:tibaneapp/services/chiefstaker_api.dart';
import 'package:tibaneapp/services/rpc_service.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/gradient_button.dart';
import 'package:tibaneapp/widgets/tibane_card.dart';
import 'package:tibaneapp/widgets/token_icon.dart';

class _Rpc extends RpcService {
  _Rpc() : super.real();

  int? holderLimit;

  @override
  Future<TokenMetadata?> getAssetFromModChain(String mint) async =>
      TokenMetadata(
        mint: mint,
        name: 'Tibanne Thecat',
        symbol: 'ChiefPussy',
        pricePerToken: 0.00016272,
        supply: BigInt.from(969900000000000),
      );

  @override
  Future<List<TokenHolder>> getTopHolders(String mint, {int limit = 10}) async {
    holderLimit = limit;
    return List.generate(
      10,
      (i) =>
          TokenHolder(address: 'holder-$i', amount: BigInt.one, percentage: 1),
    ).take(limit).toList();
  }

  @override
  Future<Uint8List?> getSharingConfig(String mint) async => null;
}

class _Pools extends ChiefStakerApi {
  _Pools() : super.real();

  @override
  Future<StakingPool?> getByMint(String mint) async => StakingPool.fromApi({
    'Mint': mint,
    'Pool_Address': 'test-pool',
    'Name': 'Tibanne Thecat',
  });
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'token info shows market stats and routes Fee Sharing via staking',
    (tester) async {
      tester.view.physicalSize = const Size(786, 1704);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rpc = _Rpc();
      RpcService.testInstance = rpc;
      ChiefStakerApi.testInstance = _Pools();
      addTearDown(() {
        RpcService.testInstance = null;
        ChiefStakerApi.testInstance = null;
      });
      final wallet = WalletService();
      final compliance = UkComplianceService();
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
          child: MaterialApp(
            locale: const Locale('en'),
            theme: TibaneTheme.darkTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const TokenDetailScreen(mint: chiefPussyMint),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(rpc.holderLimit, 5);
      expect(find.text('#5'), findsOneWidget);
      expect(find.text('#6'), findsNothing);
      final viewHolders = find.widgetWithText(
        SecondaryButton,
        'View all holders',
      );
      expect(tester.widget<SecondaryButton>(viewHolders).icon, isNull);
      expect(find.text('Fee Sharing'), findsNothing);
      expect(
        tester.widget<TokenIcon>(find.byType(TokenIcon)).useOnlyProvidedImage,
        isTrue,
      );
      expect(
        tester.widget<Text>(find.text(r'$ChiefPussy')).style!.color,
        TibaneColors.textMuted,
      );
      expect(
        tester.widget<Text>(find.text('DRtvT...hpump')).style!.color,
        TibaneColors.orange,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.copy)).color,
        TibaneColors.orange,
      );

      final cap = find.text('MARKET CAP');
      final price = find.text('PRICE');
      expect(find.text('SUPPLY'), findsNothing);
      expect(find.text('969.9M'), findsNothing);
      expect(tester.getTopLeft(cap).dx, lessThan(tester.getTopLeft(price).dx));
      expect(tester.getTopLeft(cap).dy, tester.getTopLeft(price).dy);
      for (final title in [
        'MARKET CAP',
        'PRICE',
        'Staking Pool',
        'TOP HOLDERS',
      ]) {
        expect(tester.widget<Text>(find.text(title)).style!.fontSize, 13.75);
      }
      expect(find.byIcon(Icons.account_balance), findsNothing);
      expect(tester.widget<Text>(find.text('#5')).style!.fontSize, 13.2);
      expect(tester.widget<Text>(find.text('holder-0')).style!.fontSize, 14.4);
      final percentage = tester.widget<Text>(find.text('1.00%').first).style!;
      expect(percentage.fontSize, 14.4);
      expect(percentage.fontWeight, FontWeight.w500);
      expect(
        tester.widget<Text>(find.text(r'$157.8K')).style!.color,
        TibaneColors.text,
      );
      final capCard = find.widgetWithText(TibaneCard, r'$157.8K');
      for (final value in [r'$157.8K', r'$0.00016272']) {
        final card = find.widgetWithText(TibaneCard, value);
        expect(card, findsOneWidget);
        expect(tester.getSize(card), tester.getSize(capCard));
        expect(
          tester.widget<Text>(find.text(value)).style!.fontSize,
          closeTo(25.3, 0.01),
        );
      }
      expect(
        tester.getTopLeft(price).dy,
        lessThan(tester.getTopLeft(find.text(r'$0.00016272')).dy),
      );
      expect(find.byIcon(Icons.attach_money), findsNothing);
      expect(find.byIcon(Icons.pie_chart), findsNothing);
      expect(tester.takeException(), isNull);

      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      final launchedUrls = <String>[];
      messenger.setMockMethodCallHandler(launcher, (call) async {
        expect(call.method, 'launch');
        launchedUrls.add(call.arguments['url'] as String);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
      await tester.ensureVisible(viewHolders);
      await tester.tap(viewHolders);
      await tester.pumpAndSettle();
      expect(find.text('Open Solscan?'), findsOneWidget);
      expect(launchedUrls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(launchedUrls, isEmpty);

      await tester.tap(viewHolders);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(launchedUrls, [
        'https://solscan.io/token/$chiefPussyMint#holders',
      ]);

      await tester.ensureVisible(find.text('Staking Pool'));
      await tester.tap(find.text('Staking Pool'));
      await tester.pumpAndSettle();
      expect(find.byType(StakingDetailScreen), findsOneWidget);
      await tester.ensureVisible(find.text('Fee Sharing'));
      await tester.tap(find.text('Fee Sharing'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FeeSharingScreen>(find.byType(FeeSharingScreen)).mint,
        chiefPussyMint,
      );
    },
  );
}
