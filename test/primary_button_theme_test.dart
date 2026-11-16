import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/gradient_button.dart';
import 'package:tibaneapp/widgets/token_picker_tile.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'solid accents and the verified badge match without recoloring gradients',
    (tester) async {
      const warmOrange = Color(0xFFFF843A);
      final theme = TibaneTheme.darkTheme;
      expect(theme.colorScheme.primary, warmOrange);
      expect(theme.bottomNavigationBarTheme.selectedItemColor, warmOrange);
      final badge = await tester.runAsync(
        () => rootBundle.loadString('assets/icons/verified-orange.svg'),
      );
      expect(badge, contains('fill="#ff843a"'));
      expect(TibaneColors.primaryButtonGradient.colors, [
        const Color(0xFFFFAD42),
        const Color(0xFFFF6B2C),
      ]);
    },
  );

  testWidgets('verified badge renders the accent even with the old icon fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: VerifiedTokenBadge()),
      ),
    );
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    final asset = picture.bytesLoader as SvgAssetLoader;
    final pixelColors = await tester.runAsync(() async {
      final source = await rootBundle.loadString(asset.assetName);
      final oldSource = source.replaceFirst('fill="#ff843a"', 'fill="#ff6b2c"');
      final colors = <int>[];
      for (final loader in [
        asset,
        SvgStringLoader(oldSource, colorMapper: asset.colorMapper),
      ]) {
        final info = await vg.loadPicture(loader, null);
        final image = await info.picture.toImage(64, 64);
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          colors
            ..add(pixels.getUint32((13 * 64 + 32) * 4))
            ..add(pixels.getUint32((40 * 64 + 28) * 4));
        } finally {
          image.dispose();
          info.picture.dispose();
        }
      }
      return colors;
    });
    expect(pixelColors, [0xFF843AFF, 0xFFFFFFFF, 0xFF843AFF, 0xFFFFFFFF]);
  });

  testWidgets('only enabled orange buttons get the shared gradient', (
    tester,
  ) async {
    var taps = 0;
    void onPressed() => taps++;
    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        home: Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: onPressed, child: const Text('Primary')),
              ElevatedButton(
                onPressed: onPressed,
                child: const Text('Elevated'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: onPressed,
                child: const Text('Confirm'),
              ),
              GradientButton(label: 'Shared widget', onPressed: onPressed),
              const FilledButton(onPressed: null, child: Text('Disabled')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.surface,
                ),
                onPressed: onPressed,
                child: const Text('Gray'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: TibaneColors.error,
                ),
                onPressed: onPressed,
                child: const Text('Destructive'),
              ),
            ],
          ),
        ),
      ),
    );

    final gradientInks = tester
        .widgetList<Ink>(find.byType(Ink))
        .where(
          (ink) =>
              ink.decoration is ShapeDecoration &&
              (ink.decoration as ShapeDecoration).gradient ==
                  TibaneColors.primaryButtonGradient,
        );
    expect(gradientInks, hasLength(3));
    final confirmBackground = tester.widget<Ink>(
      find.ancestor(of: find.text('Confirm'), matching: find.byType(Ink)),
    );
    final confirmShape =
        (confirmBackground.decoration as ShapeDecoration).shape;
    expect(
      confirmShape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
    final outline = confirmShape.getOuterPath(
      const Rect.fromLTWH(0, 0, 160, 48),
    );
    expect(outline.contains(const Offset(1, 1)), isFalse);
    expect(outline.contains(const Offset(80, 24)), isTrue);
    final gradientWidget = find.ancestor(
      of: find.text('Shared widget'),
      matching: find.byType(AnimatedContainer),
    );
    expect(
      (tester.widget<AnimatedContainer>(gradientWidget.first).decoration
              as BoxDecoration)
          .gradient,
      TibaneColors.primaryButtonGradient,
    );
    for (final label in ['Primary', 'Elevated']) {
      expect(
        DefaultTextStyle.of(tester.element(find.text(label))).style.color,
        TibaneColors.black,
      );
      await tester.tap(find.text(label));
    }
    expect(taps, 2);
  });
}
