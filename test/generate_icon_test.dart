import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tibaneapp/widgets/cat_logo.dart';

void main() {
  testWidgets('generate app icon', (tester) async {
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          width: 1024,
          height: 1024,
          color: const Color(0xFF030305),
          alignment: Alignment.center,
          child: const CatLogo(size: 700, glow: true),
        ),
      ),
    );

    await expectLater(
      find.byType(Container),
      matchesGoldenFile('app_icon.png'),
    );

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
