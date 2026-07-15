import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';

/// Renders the send-screen strings under each shipped locale. The full
/// SendScreen needs a WalletService/libwallet harness to pump, so this exercises
/// the same AppLocalizations getters the screen uses (title, button, review
/// title, and a placeholder-interpolated balance) and asserts the translated
/// output actually renders per locale.
void main() {
  Widget probe(Locale locale) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return Scaffold(
          body: Column(
            children: [
              Text(l10n.sendTitle('SOL')),
              Text(l10n.sendButton),
              Text(l10n.sendReviewTitle),
              Text(l10n.sendBalanceLabel('1.5', 'SOL')),
            ],
          ),
        );
      },
    ),
  );

  testWidgets('English', (tester) async {
    await tester.pumpWidget(probe(const Locale('en')));
    expect(find.text('Send SOL'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Review send'), findsOneWidget);
    expect(find.text('Balance: 1.5 SOL'), findsOneWidget);
  });

  testWidgets('French', (tester) async {
    await tester.pumpWidget(probe(const Locale('fr')));
    expect(find.text('Envoyer SOL'), findsOneWidget);
    expect(find.text('Envoyer'), findsOneWidget);
    expect(find.text("Vérifier l'envoi"), findsOneWidget);
    // French uses a non-breaking space before ':' (NBSP, U+00A0).
    expect(find.text('Solde : 1.5 SOL'), findsOneWidget);
  });

  testWidgets('Japanese', (tester) async {
    await tester.pumpWidget(probe(const Locale('ja')));
    expect(find.text('SOLを送信'), findsOneWidget);
    expect(find.text('送信'), findsOneWidget);
    expect(find.text('残高: 1.5 SOL'), findsOneWidget);
  });

  testWidgets('Brazilian Portuguese', (tester) async {
    await tester.pumpWidget(probe(const Locale('pt')));
    expect(find.text('Enviar SOL'), findsOneWidget);
    expect(find.text('Enviar'), findsOneWidget);
    expect(find.text('Saldo: 1.5 SOL'), findsOneWidget);
  });
}
