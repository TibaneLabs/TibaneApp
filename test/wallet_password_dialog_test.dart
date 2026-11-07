import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/widgets/sign_sheet.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/gradient_button.dart';

Wallet _wallet({
  String protocol = 'mnemonic',
  int threshold = 0,
  List<String> types = const ['Password'],
}) => Wallet(
  id: 'selected-fixture-wallet',
  name: 'Fixture',
  curve: 'ed25519',
  protocol: protocol,
  threshold: threshold,
  gen: 0,
  pubkey: 'public-fixture',
  chaincode: '',
  created: DateTime.utc(2026),
  modified: DateTime.utc(2026),
  keys: [
    for (final (index, type) in types.indexed)
      WalletKey(
        id: 'selected-$type-$index',
        wallet: 'selected-fixture-wallet',
        type: type,
        key: 'public-fixture',
        gen: 0,
      ),
  ],
);

class _Harness {
  List<SigningKey>? result;
  bool completed = false;
  int deviceReads = 0;
}

Future<(_Harness, AppLocalizations)> _open(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
  double scale = 1,
  double keyboard = 0,
  Wallet? wallet,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: TibaneTheme.darkTheme,
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              harness.result = await showSignSheet(
                context,
                wallet: wallet ?? _wallet(),
                readStoreKey: (_, _) async {
                  harness.deviceReads++;
                  return 'fixture-device-key';
                },
                title: 'Fixture operation',
                actionLabel: 'Confirm fixture',
              );
              harness.completed = true;
            },
            child: const Text('Open authorization'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open authorization'));
  await tester.pumpAndSettle();
  return (
    harness,
    AppLocalizations.of(tester.element(find.byType(Scaffold).first)),
  );
}

Future<void> _enterAndConfirm(WidgetTester tester, String value) async {
  final input = find.byKey(const Key('wallet-password-input'));
  await tester.ensureVisible(input);
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
  final ok = find.byKey(const Key('wallet-password-ok'));
  await tester.ensureVisible(ok);
  await tester.tap(ok);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(320, 568), const Size(393, 852)]) {
      for (final scale in [1.0, 1.5]) {
        testWidgets(
          'seed opens only the password dialog without a logo: $language $size scale $scale',
          (tester) async {
            final (harness, l10n) = await _open(
              tester,
              language: language,
              size: size,
              scale: scale,
            );
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.byType(BottomSheet), findsNothing);
            expect(find.byType(ListTile), findsNothing);
            expect(find.byType(GradientButton), findsNothing);
            expect(find.text('Fixture operation'), findsNothing);
            expect(find.byType(Image), findsNothing);
            final titleFinder = find.byKey(const Key('wallet-password-title'));
            final title = tester.widget<Text>(titleFinder);
            expect(title.data, l10n.signSheetPasswordTitle);
            expect(title.textAlign, TextAlign.center);
            final theme = Theme.of(tester.element(titleFinder));
            final base =
                theme.dialogTheme.titleTextStyle ??
                theme.textTheme.headlineSmall!;
            expect(
              title.style!.fontSize,
              closeTo((base.fontSize ?? 24) * 1.15, 0.001),
            );
            expect(title.style!.fontWeight, FontWeight.w500);
            expect(title.style!.fontVariations, isNull);
            expect(
              title.style!.fontFamily,
              GoogleFonts.dmSans(fontWeight: FontWeight.w500).fontFamily,
            );
            expect(
              title.style!.fontFamily,
              isNot(GoogleFonts.dmSans(fontWeight: FontWeight.w400).fontFamily),
            );
            final input = tester.widget<TextField>(
              find.byKey(const Key('wallet-password-input')),
            );
            expect(input.obscureText, isTrue);
            expect(input.autocorrect, isFalse);
            expect(input.enableSuggestions, isFalse);
            expect(input.enableIMEPersonalizedLearning, isFalse);
            expect(input.decoration!.labelText, isNull);
            expect(input.decoration!.hintText, isNull);
            final cancel = tester.widget<TextButton>(
              find.byKey(const Key('wallet-password-cancel')),
            );
            expect(
              cancel.style!.side?.resolve({}) ?? BorderSide.none,
              BorderSide.none,
            );
            expect(
              cancel.style!.foregroundColor!.resolve({}),
              TibaneColors.orange,
            );
            final ok = tester.widget<FilledButton>(
              find.byKey(const Key('wallet-password-ok')),
            );
            expect(ok.style!.backgroundColor!.resolve({}), TibaneColors.orange);
            expect(ok.onPressed, isNull);
            if (size.width == 393) {
              expect(
                tester.getSize(find.byType(AlertDialog)).width,
                greaterThan(320),
              );
            }
            expect(harness.completed, isFalse);
            await _enterAndConfirm(tester, '  fixture password  ');
            expect(harness.completed, isTrue);
            expect(harness.result, hasLength(1));
            expect(harness.result!.single.id, 'selected-Password-0');
            expect(harness.result!.single.key, '  fixture password  ');
            expect(harness.result!.single.type, 'Password');
            expect(harness.deviceReads, 0);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(BottomSheet), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final size in [const Size(320, 568), const Size(393, 852)]) {
    testWidgets(
      'password field and buttons remain usable above the keyboard: $size',
      (tester) async {
        final (harness, _) = await _open(
          tester,
          size: size,
          keyboard: 250,
          scale: 1.5,
        );
        await _enterAndConfirm(tester, 'fixture-password');
        expect(harness.completed, isTrue);
        expect(harness.result, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel does not authorize and reopening starts empty', (
    tester,
  ) async {
    final (harness, _) = await _open(tester);
    await tester.enterText(
      find.byKey(const Key('wallet-password-input')),
      'fixture-password',
    );
    await tester.tap(find.byKey(const Key('wallet-password-cancel')));
    await tester.pumpAndSettle();
    expect(harness.completed, isTrue);
    expect(harness.result, isNull);
    await tester.tap(find.text('Open authorization'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('wallet-password-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('empty keyboard submission cannot authorize', (tester) async {
    final (harness, _) = await _open(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(harness.completed, isFalse);
    await tester.enterText(
      find.byKey(const Key('wallet-password-input')),
      'fixture-password',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(harness.result!.single.key, 'fixture-password');
  });

  testWidgets(
    'leaving the foreground clears the field and cancels authorization',
    (tester) async {
      final (harness, _) = await _open(tester);
      final controller = tester
          .widget<TextField>(find.byKey(const Key('wallet-password-input')))
          .controller!;
      await tester.enterText(
        find.byKey(const Key('wallet-password-input')),
        'fixture-password',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(controller.text, isEmpty);
      await tester.pumpAndSettle();
      expect(harness.completed, isTrue);
      expect(harness.result, isNull);
      expect(find.text('Open authorization'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  testWidgets(
    'MPC keeps its share sheet and uses the same styled password dialog',
    (tester) async {
      final (harness, l10n) = await _open(
        tester,
        wallet: _wallet(
          protocol: 'frost',
          threshold: 1,
          types: ['Password', 'StoreKey', 'RemoteKey'],
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(3));
      await tester.tap(find.text(l10n.signSheetKeyTitle('1', 'Password')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      await _enterAndConfirm(tester, 'fixture-password');
      expect(harness.completed, isFalse);
      expect(
        tester.widget<GradientButton>(find.byType(GradientButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text(l10n.signSheetKeyTitle('2', 'StoreKey')));
      await tester.pumpAndSettle();
      expect(harness.deviceReads, 1);
      await tester.tap(find.text('Confirm fixture'));
      await tester.pumpAndSettle();
      expect(harness.result!.map((key) => key.type), ['Password', 'StoreKey']);
    },
  );

  testWidgets('two password MPC shares are not mistaken for an ordinary seed', (
    tester,
  ) async {
    final (harness, l10n) = await _open(
      tester,
      wallet: _wallet(
        protocol: 'dkls23',
        threshold: 1,
        types: ['Password', 'Password', 'RemoteKey'],
      ),
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text(l10n.signSheetKeyTitle('1', 'Password')));
    await tester.pumpAndSettle();
    await _enterAndConfirm(tester, 'fixture-password');
    await tester.tap(find.text(l10n.signSheetKeyTitle('2', 'Password')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Confirm fixture'));
    await tester.pumpAndSettle();
    expect(harness.result, hasLength(2));
    expect(harness.result!.map((key) => key.id).toSet(), {
      'selected-Password-0',
      'selected-Password-1',
    });
  });
}
