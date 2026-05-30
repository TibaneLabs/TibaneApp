import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/widgets/keyboard_safe_form.dart';

/// KeyboardSafeForm is the fix for "RenderFlex overflowed … on the bottom"
/// on Spacer-pinned button forms when the keyboard shrinks the viewport.
void main() {
  testWidgets('wraps the form in a scroll view and renders the child', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KeyboardSafeForm(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Text('intro'), Spacer(), Text('BUTTON')],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('intro'), findsOneWidget);
    expect(find.text('BUTTON'), findsOneWidget);
  });

  testWidgets('does NOT overflow when the viewport is tiny (keyboard open)', (
    tester,
  ) async {
    // A short viewport — like when the on-screen keyboard is up.
    tester.view.physicalSize = const Size(400, 220);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KeyboardSafeForm(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: 300), // taller than the viewport
                Spacer(),
                Text('BUTTON'),
              ],
            ),
          ),
        ),
      ),
    );

    // The bare Column+Spacer would throw "RenderFlex overflowed" here; the
    // scroll-wrapped form must not.
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
