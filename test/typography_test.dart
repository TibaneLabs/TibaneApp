import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'shared detail text uses DM Sans and preserves sizing and emphasis',
    (tester) async {
      final style = monoStyle(fontSize: 18.4, color: TibaneColors.orange);
      expect(style.fontFamily, GoogleFonts.dmSans().fontFamily);
      expect(style.fontSize, 18.4);
      expect(style.color, TibaneColors.orange);
      expect(style.letterSpacing, 0);
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(style.fontFamilyFallback, cjkFallback);
      final emphasized = style.copyWith(fontWeight: FontWeight.w600);
      expect(emphasized.fontWeight, FontWeight.w600);
      expect(emphasized.fontFamily, style.fontFamily);
      expect(emphasized.fontSize, style.fontSize);
      await tester.pumpWidget(
        MaterialApp(home: Text('0.001 SOL', style: emphasized)),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('small labels and titles use the same DM Sans family', (
    tester,
  ) async {
    final theme = TibaneTheme.darkTheme;
    expect(
      theme.chipTheme.labelStyle!.fontFamily,
      GoogleFonts.dmSans().fontFamily,
    );
    expect(theme.chipTheme.labelStyle!.fontSize, 11);
    expect(theme.chipTheme.labelStyle!.letterSpacing, 0);
    expect(theme.appBarTheme.titleTextStyle!.fontFamily, startsWith('DMSans'));
    expect(theme.appBarTheme.titleTextStyle!.fontWeight, FontWeight.w700);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: const Chip(label: Text('SOL')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}
