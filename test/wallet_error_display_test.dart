import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart' show LibwalletException;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/widgets/wallet_error_display.dart';

/// Widget tests for the [WalletError] display helpers — friendly message shown,
/// silent errors suppressed, raw detail reachable + copyable, and the raw
/// always logged when the error is surfaced. See ERROR_DISPLAY_AUDIT.md.
void main() {
  // An error whose real reason ("insufficient lamports") lives in the message
  // and maps to a friendly line, with the raw kept as detail.
  const insufficient =
      LibwalletException(message: 'insufficient lamports', code: '500');
  const friendly = "You don't have enough balance to cover this transaction.";

  group('showWalletError', () {
    testWidgets('shows a SnackBar with the friendly message', (tester) async {
      await _pumpTrigger(tester, insufficient);
      await tester.tap(find.text('go'));
      await tester.pump(); // let the SnackBar appear

      expect(find.text(friendly), findsOneWidget);
      expect(find.text('insufficient lamports'), findsNothing); // raw hidden
    });

    testWidgets('is silent for a user-rejected (4001) error', (tester) async {
      await _pumpTrigger(tester,
          const LibwalletException(message: 'User rejected', code: '4001'));
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Details action opens a sheet exposing the raw text',
        (tester) async {
      await _pumpTrigger(tester, insufficient);
      await tester.tap(find.text('go'));
      await tester.pump(); // schedule the SnackBar
      await tester.pump(const Duration(milliseconds: 400)); // finish entrance

      expect(find.text('Details'), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();

      expect(find.text('insufficient lamports'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });
  });

  group('walletErrorCard', () {
    testWidgets('renders the friendly message', (tester) async {
      await _pumpCard(tester, walletErrorCard(insufficient));
      expect(find.text(friendly), findsOneWidget);
      expect(find.text('insufficient lamports'), findsNothing);
    });

    testWidgets('Details toggles the raw text inline', (tester) async {
      await _pumpCard(tester, walletErrorCard(insufficient));
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.text('insufficient lamports'), findsOneWidget);

      await tester.tap(find.text('Hide details'));
      await tester.pump();
      expect(find.text('insufficient lamports'), findsNothing);
    });

    testWidgets('renders nothing for a silent error', (tester) async {
      await _pumpCard(
          tester,
          walletErrorCard(
              const LibwalletException(message: 'User rejected', code: '4001')));
      expect(find.byType(SizedBox), findsWidgets); // shrink
      expect(find.text('Request cancelled.'), findsNothing);
    });

    testWidgets('shows a Retry affordance when onRetry is given',
        (tester) async {
      var retried = false;
      await _pumpCard(
          tester, walletErrorCard(insufficient, onRetry: () => retried = true));
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });
  });

  group('logging (Log user errors rule)', () {
    testWidgets('the raw detail is logged when the error is shown',
        (tester) async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        await _pumpCard(tester, walletErrorCard(insufficient));
      } finally {
        debugPrint = original;
      }
      expect(logs.any((l) => l.contains('insufficient lamports')), isTrue,
          reason: 'raw error text must reach the debug log');
      expect(logs.any((l) => l.contains('[WalletError]')), isTrue);
    });
  });
}

/// Pump a screen with a button that fires [showWalletError] for [error].
Future<void> _pumpTrigger(WidgetTester tester, Object error) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showWalletError(context, error),
          child: const Text('go'),
        ),
      ),
    ),
  ));
}

/// Pump [child] inside a scaffold so cards render with a Material ancestor.
Future<void> _pumpCard(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
}
