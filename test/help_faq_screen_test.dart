import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/l10n/l10n.dart';
import 'package:tibaneapp/screens/settings/help_faq_screen.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'FAQ expands and fits a narrow screen in ${locale.languageCode}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: const HelpFaqScreen(),
          ),
        );
        final l10n = tester.element(find.byType(HelpFaqScreen)).l10n;
        final section = find.text(l10n.helpFaqBackupsGroup);
        expect(tester.widget<Text>(section).style!.fontSize, 19.5);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.backup_outlined)).size,
          closeTo(23.4, 0.001),
        );
        final question = find.text(l10n.helpFaqBackupHowQ);
        expect(
          tester.widget<Text>(question).style!.fontSize,
          closeTo(16.8, 0.001),
        );
        await tester.tap(question);
        await tester.pumpAndSettle();
        final answer = find.text(l10n.helpFaqBackupHowA);
        expect(
          tester.widget<Text>(answer).style!.fontSize,
          closeTo(14.95, 0.001),
        );

        final lostContact = find.text(l10n.helpFaqLostMpcContactQ);
        await tester.scrollUntilVisible(lostContact, 200);
        await tester.ensureVisible(lostContact);
        await tester.pumpAndSettle();
        await tester.tap(lostContact);
        await tester.pumpAndSettle();
        expect(find.text(l10n.helpFaqLostMpcContactA), findsOneWidget);

        final reclaim = find.text(l10n.helpFaqReclaimQ);
        await tester.scrollUntilVisible(reclaim, 250);
        await tester.ensureVisible(reclaim);
        await tester.pumpAndSettle();
        await tester.tap(reclaim);
        await tester.pumpAndSettle();
        expect(find.text(l10n.helpFaqReclaimA), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
