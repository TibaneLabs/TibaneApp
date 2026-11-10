import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tibaneapp/main.dart';

void main() {
  testWidgets('App renders the branded startup splash', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const TibaneApp());
    // The global security preference loads before any app content is visible.
    expect(find.text('Tibane Labs'), findsNothing);
    await tester.pump();
    // With app lock disabled, the branded startup gate can become visible.
    expect(find.text('Tibane Labs'), findsOneWidget);
  });
}
