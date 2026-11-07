import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _from = 'CBcWENrpEfVBcU9gu5b5mdSBsfyzkV8UyPXenSniWS3o';
const _to = '9Geyod8NY1iizHWuyghULybsk4WzE3B3PdBToQQmWPXs';

Future<void> _pump(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
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
      home: SendSuccessScreen(
        symbol: 'SOL',
        fromAddress: _from,
        toAddress: _to,
        txHash: '1234567890abcdefghij',
        net: Network(
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(375, 667), const Size(393, 852)]) {
      testWidgets('compact send success in $language at $size', (tester) async {
        await _pump(tester, language: language, size: size);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(SendSuccessScreen)),
        );
        expect(
          tester.widget<Text>(find.text(l10n.transactionSubmittedTitle)).style!.fontSize,
          closeTo(28.6, 0.001),
        );
        for (final label in [l10n.labelFrom, l10n.labelTo]) {
          expect(
            tester.widget<Text>(find.text(label)).style!.fontSize,
            closeTo(13.2, 0.001),
          );
        }
        expect(find.byIcon(Icons.north_east), findsNothing);
        expect(find.text(l10n.transactionSubmittedBody), findsOneWidget);
        expect(find.text(l10n.sendSuccessTitle), findsNothing);
        expect(find.byIcon(Icons.south_west), findsNothing);
        expect(find.byIcon(Icons.ios_share), findsNothing);
        expect(find.text(l10n.sendShareReceipt), findsNothing);
        expect(find.text('CBcWE...iWS3o'), findsOneWidget);
        expect(find.text('9Geyo...mWPXs'), findsOneWidget);
        expect(find.text(_from), findsNothing);
        expect(find.text(_to), findsNothing);
        final explorer = find.text(l10n.viewOnExplorerNamed('Solscan'));
        await tester.ensureVisible(explorer);
        await tester.pumpAndSettle();
        expect(explorer, findsOneWidget);
        expect(find.text(l10n.backToHome), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('shortened addresses still copy their complete value', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(call.arguments['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, size: const Size(393, 1200));
    await tester.tap(find.text(abbreviateAccountAddress(_from)));
    await tester.pump();
    await tester.tap(find.text(abbreviateAccountAddress(_to)));
    await tester.pump();
    expect(copied, [_from, _to]);
    expect(tester.takeException(), isNull);
  });
}
