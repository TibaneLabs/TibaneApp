import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/main.dart';

/// Unit tests for the per-tab-Navigator shell (NAVIGATION_MIGRATION.md). The
/// full shell can't be pumped here — it holds on the startup gate without a
/// WalletService/libwallet harness — so the two pieces of new decision logic
/// are extracted as pure helpers and verified directly.
void main() {
  group('shellBackAction — system back routing (D-nav-3)', () {
    test('active tab has a pushed route -> pop within the tab', () {
      expect(
        shellBackAction(activeTabCanPop: true),
        ShellBackAction.popTab,
      );
    });

    test('active tab is at its root -> exit the app (pre-migration parity)', () {
      expect(
        shellBackAction(activeTabCanPop: false),
        ShellBackAction.exitApp,
      );
    });
  });

  group('browserTabState — lazy build + pause', () {
    test('never visited & not on Browse -> webview not built, inactive', () {
      final s = browserTabState(wasVisited: false, activeIndex: 0);
      expect(s.visited, isFalse);
      expect(s.active, isFalse);
    });

    test('opening Browse builds the webview and marks it active', () {
      final s = browserTabState(wasVisited: false, activeIndex: 2);
      expect(s.visited, isTrue);
      expect(s.active, isTrue);
    });

    test('leaving Browse keeps it built but pauses it', () {
      final s = browserTabState(wasVisited: true, activeIndex: 1);
      expect(s.visited, isTrue);
      expect(s.active, isFalse);
    });

    test('returning to Browse re-activates the already-built webview', () {
      final s = browserTabState(wasVisited: true, activeIndex: 2);
      expect(s.visited, isTrue);
      expect(s.active, isTrue);
    });

    test('cold-start on Browse (initialIndex 2) builds immediately', () {
      final s = browserTabState(wasVisited: false, activeIndex: 2);
      expect(s.visited, isTrue);
      expect(s.active, isTrue);
    });

    test('visited latch never regresses once set', () {
      var s = browserTabState(wasVisited: false, activeIndex: 2); // open
      s = browserTabState(wasVisited: s.visited, activeIndex: 0); // leave
      s = browserTabState(wasVisited: s.visited, activeIndex: 3); // elsewhere
      expect(s.visited, isTrue);
      expect(s.active, isFalse);
    });
  });
}
