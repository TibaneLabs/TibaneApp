import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _recipient = '9Geyod8NY1iizHWuyghULybsk4WzE3B3PdBToQQmWPXs';

Network _network(NetworkType type, String symbol) => Network(
  id: type.name,
  type: type,
  chainId: type.name,
  name: type == NetworkType.solana ? 'Solana' : symbol,
  rpc: '',
  currencySymbol: symbol,
  currencyDecimals: type == NetworkType.evm ? 18 : 9,
  blockExplorer: '',
  testNet: false,
  priority: 0,
  created: DateTime.utc(2026),
  updated: DateTime.utc(2026),
);

Future<void> _pump(
  WidgetTester tester, {
  required TransactionSimulation simulation,
  String language = 'en',
  Size size = const Size(393, 852),
  NetworkType networkType = NetworkType.solana,
  String currency = 'SOL',
  String token = 'SOL',
  String? recipientName,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      theme: TibaneTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => SendReviewSheet(
                to: _recipient,
                recipientName: recipientName,
                amountUi: 0.008927781,
                symbol: token,
                decimals: 9,
                imageUrl: null,
                iconMint: token == 'SOL' ? wsolMint : '',
                net: _network(networkType, currency),
                sim: simulation,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(375, 667), const Size(393, 852)]) {
      testWidgets('review typography and fee fit $language at $size', (
        tester,
      ) async {
        await _pump(
          tester,
          language: language,
          size: size,
          simulation: TransactionSimulation(
            chain: 'solana',
            willRevert: false,
            fee: Amount(BigInt.from(5000), 9),
          ),
        );
        final context = tester.element(find.byType(SendReviewSheet));
        final l10n = AppLocalizations.of(context);
        expect(
          tester
              .widget<Text>(find.text(l10n.sendReviewSubtitle))
              .style!
              .fontSize,
          closeTo(14.95, 0.001),
        );
        expect(
          tester.widget<Text>(find.text(l10n.labelTo)).style!.fontSize,
          closeTo(16.9, 0.001),
        );
        expect(
          tester.widget<Text>(find.text(_recipient)).style!.fontSize,
          closeTo(18.6875, 0.001),
        );
        expect(
          tester.widget<Text>(find.text(_recipient)).style!.fontWeight,
          FontWeight.w500,
        );
        expect(find.text(l10n.sendRecipientPill), findsNothing);
        expect(find.text('0.000005 SOL'), findsOneWidget);
        final fee = find.byKey(const Key('send-review-network-fee'));
        await tester.ensureVisible(fee);
        await tester.pumpAndSettle();
        final feeLabel = find.text(l10n.sendEstimatedNetworkFee);
        expect(
          tester.getRect(feeLabel).right,
          lessThanOrEqualTo(tester.getRect(fee).left),
        );
        await tester.ensureVisible(find.text(l10n.actionConfirm));
        await tester.pumpAndSettle();
        final confirm = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(l10n.actionConfirm),
            matching: find.byType(FilledButton),
          ),
        );
        expect(confirm.onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('SPL fee is displayed in SOL, not the sent token', (
    tester,
  ) async {
    await _pump(
      tester,
      token: 'FLASH',
      simulation: TransactionSimulation(
        chain: 'solana',
        willRevert: false,
        fee: Amount(BigInt.from(12345), 9),
      ),
    );
    expect(find.text('0.000012345 SOL'), findsOneWidget);
  });

  testWidgets('Bitcoin-family simulation fee uses its native currency', (
    tester,
  ) async {
    await _pump(
      tester,
      token: 'LTC',
      currency: 'LTC',
      networkType: NetworkType.bitcoin,
      simulation: const TransactionSimulation(
        chain: 'bitcoin',
        willRevert: false,
        bitcoinFee: 1234,
      ),
    );
    expect(find.text('0.00001234 LTC'), findsOneWidget);
  });

  testWidgets('missing fee is unavailable, not zero or a gas-unit amount', (
    tester,
  ) async {
    await _pump(
      tester,
      token: 'ETH',
      currency: 'ETH',
      networkType: NetworkType.evm,
      simulation: const TransactionSimulation(
        chain: 'evm',
        willRevert: false,
        gasEstimate: 21000,
      ),
    );
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('0 ETH'), findsNothing);
    expect(find.textContaining('21000'), findsNothing);
  });

  testWidgets('resolved name remains visible without a recipient pill', (
    tester,
  ) async {
    await _pump(
      tester,
      recipientName: 'recipient.sol',
      simulation: const TransactionSimulation(
        chain: 'solana',
        willRevert: true,
      ),
    );
    expect(find.text('recipient.sol'), findsOneWidget);
    expect(find.text(_recipient), findsOneWidget);
    expect(find.text('Recipient'), findsNothing);
    await tester.ensureVisible(find.text('Cannot send'));
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Cannot send'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
