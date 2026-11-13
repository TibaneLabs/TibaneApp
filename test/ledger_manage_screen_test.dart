import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/ledger_manage_screen.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('renders with no Ledger connected ($locale)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(720, 1520);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final wallet = WalletService();
      addTearDown(wallet.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<WalletService>.value(
          value: wallet,
          child: MaterialApp(
            theme: TibaneTheme.darkTheme,
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LedgerManageScreen(neededApps: ['Solana', 'Bitcoin']),
          ),
        ),
      );
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(locale);
      expect(find.text(l10n.hwLedgerManageTitle), findsOneWidget);
      expect(find.text(l10n.hwLedgerNotConnected), findsOneWidget);
      expect(find.text(l10n.hwLedgerDeviceHint), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(l10n.hwLedgerInstallOther),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Solana'), findsOneWidget);
      expect(find.text('Bitcoin'), findsOneWidget);
      // Nothing was read from a device yet.
      expect(find.text(l10n.hwLedgerAppUnknown), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }
}
