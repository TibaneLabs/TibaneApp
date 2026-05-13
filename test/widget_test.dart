import 'package:flutter_test/flutter_test.dart';

import 'package:tibaneapp/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const TibaneApp());
    expect(find.text('Tibane'), findsOneWidget);
  });
}
