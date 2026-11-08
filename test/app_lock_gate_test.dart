import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/services/app_lock_controller.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/app_lock_gate.dart';

import 'helpers/app_lock_fakes.dart';

Future<GlobalKey<NavigatorState>> _pump(
  WidgetTester tester,
  AppLockController lock, {
  String language = 'en',
  double width = 393,
  double scale = 1,
  GlobalKey<ScaffoldMessengerState>? messengerKey,
}) async {
  tester.view.physicalSize = Size(width * 2, 568 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: TibaneTheme.darkTheme,
      locale: Locale(language),
      navigatorKey: navigator,
      scaffoldMessengerKey: messengerKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: AppLockGate(controller: lock, child: child!),
      ),
      home: const Scaffold(
        body: Column(
          children: [
            Text('Private account view'),
            TextField(key: Key('private-input')),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return navigator;
}

Future<void> _dispose(WidgetTester tester, AppLockController lock) async {
  await tester.pumpWidget(const SizedBox.shrink());
  lock.dispose();
  await tester.pump();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      AppLockController.preferenceKey: true,
    }),
  );

  testWidgets(
    'startup never exposes underlying routes before successful authentication',
    (tester) async {
      final auth = FakeAppLockAuthenticator()..pending = Completer<bool>();
      final lock = AppLockController(authenticator: auth);
      await lock.load();
      await _pump(tester, lock);
      expect(auth.calls, 1);
      expect(find.text('Private account view'), findsNothing);
      expect(find.byKey(const Key('app-lock-surface')), findsOneWidget);
      expect(
        find.byKey(const Key('private-input')).hitTestable(),
        findsNothing,
      );
      auth.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Private account view'), findsOneWidget);
      expect(find.byKey(const Key('app-lock-surface')), findsNothing);
      await _dispose(tester, lock);
    },
  );

  testWidgets('disabled lock never requests authentication', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final auth = FakeAppLockAuthenticator();
    final lock = AppLockController(authenticator: auth);
    await lock.load();
    await _pump(tester, lock);
    expect(auth.calls, 0);
    expect(find.text('Private account view'), findsOneWidget);
    await _dispose(tester, lock);
  });

  testWidgets(
    'a cancelled prompt stays locked without an automatic retry loop',
    (tester) async {
      final auth = FakeAppLockAuthenticator()..result = false;
      final lock = AppLockController(authenticator: auth);
      await lock.load();
      await _pump(tester, lock);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(auth.calls, 1);
      expect(find.text('Private account view'), findsNothing);
      auth.result = true;
      await tester.tap(find.byKey(const Key('app-lock-unlock')));
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(find.text('Private account view'), findsOneWidget);
      await _dispose(tester, lock);
    },
  );

  testWidgets(
    'root dialogs and deep-link routes cannot bypass a background lock',
    (tester) async {
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      await lock.load();
      final navigator = await _pump(tester, lock);
      await tester.pumpAndSettle();
      expect(find.text('Private account view'), findsOneWidget);
      auth.result = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Deep-link private view')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private account view'), findsNothing);
      expect(find.text('Deep-link private view'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(find.text('Deep-link private view'), findsNothing);
      auth.result = true;
      await tester.tap(find.byKey(const Key('app-lock-unlock')));
      await tester.pumpAndSettle();
      expect(find.text('Deep-link private view'), findsOneWidget);
      await _dispose(tester, lock);
    },
  );

  testWidgets(
    'inactive native prompts cover content but do not ask to unlock the app again',
    (tester) async {
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(authenticator: auth);
      await lock.load();
      await _pump(tester, lock);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('Private account view'), findsNothing);
      expect(find.byKey(const Key('app-lock-unlock')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private account view'), findsOneWidget);
      expect(auth.calls, 1);
      await _dispose(tester, lock);
    },
  );

  testWidgets(
    'security-setting read failure stays covered until retry and authentication succeed',
    (tester) async {
      var fail = true;
      final auth = FakeAppLockAuthenticator();
      final lock = AppLockController(
        authenticator: auth,
        readEnabled: () async {
          if (fail) throw StateError('Fixture load failed');
          return true;
        },
      );
      await lock.load();
      await _pump(tester, lock);
      expect(find.text('Private account view'), findsNothing);
      expect(auth.calls, 0);
      fail = false;
      await tester.tap(find.byKey(const Key('app-lock-unlock')));
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      expect(find.text('Private account view'), findsOneWidget);
      await _dispose(tester, lock);
    },
  );

  testWidgets('background app messages cannot appear over the lock screen', (
    tester,
  ) async {
    final auth = FakeAppLockAuthenticator()..result = false;
    final lock = AppLockController(authenticator: auth);
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await lock.load();
    await _pump(tester, lock, messengerKey: messenger);
    messenger.currentState!.showSnackBar(
      const SnackBar(content: Text('Private background notice')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private background notice'), findsNothing);
    expect(find.byKey(const Key('app-lock-surface')), findsOneWidget);
    await _dispose(tester, lock);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'lock screen fits ${locale.languageCode} at 320px with large text',
      (tester) async {
        final auth = FakeAppLockAuthenticator()..result = false;
        final lock = AppLockController(authenticator: auth);
        await lock.load();
        await _pump(
          tester,
          lock,
          language: locale.languageCode,
          width: 320,
          scale: 1.5,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('app-lock-unlock')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _dispose(tester, lock);
      },
    );
  }
}
