import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/recover_funds_screen.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

RecoveredAddress _row(int index, {bool funded = false}) => RecoveredAddress(
  id: 'bitcoin:p2wpkh:m/84\'/0\'/0\'/0/$index',
  chain: 'bitcoin',
  symbol: 'BTC',
  kind: 'p2wpkh',
  address: 'bc1-$index',
  label: 'Native SegWit $index',
  index: index,
  layout: 'bip84',
  assets: funded
      ? [
          RecoveredAsset(
            asset: 'NATIVE',
            symbol: 'BTC',
            decimals: 8,
            balance: BigInt.from(1000),
          ),
        ]
      : const [],
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final language in ['en', 'fr', 'ja', 'pt']) {
    testWidgets('source step lays out every source ($language)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RecoverFundsScreen(),
        ),
      );
      for (final kind in RecoverySourceKind.values) {
        await tester.tap(find.byKey(ValueKey('recover-source-${kind.name}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('recover-secret')), findsOneWidget);
      }
      // Opening with nothing typed explains what's missing, without libwallet.
      final open = find.byKey(const ValueKey('recover-open'));
      await tester.scrollUntilVisible(
        open,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(open);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          lookupAppLocalizations(Locale(language)).recoverErrMissingInput,
        ),
        findsOneWidget,
      );
    });
  }

  test('every Bitcoin-family chain lands on a bitcoin account', () {
    for (final chain in [
      'bitcoin',
      'litecoin',
      'dogecoin',
      'bitcoin-cash',
      'monacoin',
    ]) {
      expect(recoveryAccountTypeFor(chain), 'bitcoin', reason: chain);
    }
    expect(recoveryAccountTypeFor('ethereum'), 'ethereum');
    expect(recoveryAccountTypeFor('solana'), 'solana');
    expect(recoveryAccountTypeFor('tron'), 'tron');
    expect(recoveryAccountTypeFor('monero'), isNull);
  });

  test('funds on the last index scanned ask for the next page', () {
    expect(
      recoveryShouldScanFurther(
        [_row(0, funded: true), _row(4)],
        start: 0,
        count: 5,
      ),
      isFalse,
    );
    expect(
      recoveryShouldScanFurther([_row(4, funded: true)], start: 0, count: 5),
      isTrue,
    );
    expect(
      recoveryShouldScanFurther([_row(9, funded: true)], start: 5, count: 5),
      isTrue,
    );
  });

  test('fees are counted in the native coin', () {
    expect(recoveryNativeDecimals('ethereum'), 18);
    expect(recoveryNativeDecimals('solana'), 9);
    expect(recoveryNativeDecimals('tron'), 6);
    expect(recoveryNativeDecimals('dogecoin'), 8);
  });
}
