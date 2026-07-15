import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';

/// Renders the receive- and tokens-screen strings under each shipped locale.
/// The real screens need a WalletService/libwallet harness to pump, so this
/// exercises the same AppLocalizations getters the screens use (incl. a
/// placeholder-interpolated toast) and asserts the translated output per locale.
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
              Text(l10n.receiveTitle),
              Text(l10n.receiveAddressLabelSolana),
              Text(l10n.tokensTitle),
              Text(l10n.tokensAddByAddress),
              Text(l10n.tokensAdded('USDC')),
              Text(l10n.tokensRemoveTitle),
              Text(l10n.actionRemove),
            ],
          ),
        );
      },
    ),
  );

  testWidgets('English', (tester) async {
    await tester.pumpWidget(probe(const Locale('en')));
    expect(find.text('Receive'), findsOneWidget);
    expect(find.text('Your Solana address'), findsOneWidget);
    expect(find.text('Tokens'), findsOneWidget);
    expect(find.text('Add by address'), findsOneWidget);
    expect(find.text('Added USDC'), findsOneWidget);
    expect(find.text('Remove token?'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('French', (tester) async {
    await tester.pumpWidget(probe(const Locale('fr')));
    expect(find.text('Recevoir'), findsOneWidget);
    expect(find.text('Jetons'), findsOneWidget);
    expect(find.text('USDC ajouté'), findsOneWidget);
    // French uses a non-breaking space before '?' (NBSP, U+00A0).
    expect(find.text('Supprimer le jeton ?'), findsOneWidget);
    expect(find.text('Supprimer'), findsOneWidget);
  });

  testWidgets('Japanese', (tester) async {
    await tester.pumpWidget(probe(const Locale('ja')));
    expect(find.text('受け取る'), findsOneWidget);
    expect(find.text('トークン'), findsOneWidget);
    expect(find.text('USDCを追加しました'), findsOneWidget);
    expect(find.text('トークンを削除しますか？'), findsOneWidget);
    expect(find.text('削除'), findsOneWidget);
  });

  testWidgets('Brazilian Portuguese', (tester) async {
    await tester.pumpWidget(probe(const Locale('pt')));
    expect(find.text('Receber'), findsOneWidget);
    expect(find.text('Tokens'), findsOneWidget);
    expect(find.text('USDC adicionado'), findsOneWidget);
    expect(find.text('Remover token?'), findsOneWidget);
    expect(find.text('Remover'), findsOneWidget);
  });
}
