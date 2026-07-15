import 'package:flutter_test/flutter_test.dart';

import 'package:tibaneapp/main.dart';

void main() {
  testWidgets('App renders the branded startup splash', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TibaneApp());
    // First frame holds the startup gate (D16) on the branded splash until the
    // migration check + first wallet snapshot resolve. Also exercises the
    // localization wiring (AppLocalizations delegate / onGenerateTitle) without
    // a fully settled tree.
    expect(find.text('Tibane Labs'), findsOneWidget);
  });
}
