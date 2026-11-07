import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Wallet;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/inapp_import_private_key_screen.dart';
import 'package:tibaneapp/services/wallet/logical_wallet.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

Future<void> _pumpImport(WidgetTester tester, {String language = 'en'}) async {
  tester.view.physicalSize = const Size(750, 1334);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      theme: TibaneTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const InAppImportPrivateKeyScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'import confirmation only offers Done without MPC or backup warning',
    (tester) async {
      var completions = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PrivateKeyImportConfirmation(
              address: 'PublicFixtureAddress',
              onDone: () => completions++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Upgrade to MPC'), findsNothing);
      expect(find.text('Skip for now'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      final done = find.text('Done');
      await tester.ensureVisible(done);
      await tester.tap(done);
      expect(completions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(375, 667), const Size(393, 852)]) {
      testWidgets('confirmation typography fits $language at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const address = 'CBcWENrpEfVBcU9gu5b5mdSBsfyzkV8UyPXenSniWS3o';
        var completions = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            theme: TibaneTheme.darkTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              appBar: AppBar(title: const Text('Import account')),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: PrivateKeyImportConfirmation(
                    address: address,
                    onDone: () => completions++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(
          find.byType(PrivateKeyImportConfirmation),
        );
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context).textTheme;
        final title = tester.widget<Text>(find.text(l10n.privateKeyDoneTitle));
        final body = tester.widget<Text>(find.text(l10n.privateKeyDoneBody));
        expect(find.text(l10n.privateKeyExportWarning), findsNothing);
        expect(find.text(l10n.privateKeyMpcBody), findsNothing);
        expect(find.text(l10n.privateKeyPromoteAction), findsNothing);
        expect(find.text(l10n.privateKeySkipAction), findsNothing);
        final addressText = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(
          title.style!.fontSize,
          closeTo(theme.titleLarge!.fontSize! * 1.1, 0.001),
        );
        expect(
          body.style!.fontSize,
          closeTo(theme.bodyMedium!.fontSize! * 1.1, 0.001),
        );
        expect(addressText.style!.fontSize, closeTo(16.5, 0.001));
        for (final label in [l10n.actionDone]) {
          final text = find.text(label);
          expect(
            tester.widget<Text>(text).style!.fontSize,
            closeTo(theme.labelLarge!.fontSize! * 1.1, 0.001),
          );
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          final button = find.ancestor(
            of: text,
            matching: find.byType(FilledButton),
          );
          final buttonRect = tester.getRect(button);
          final textRect = tester.getRect(text);
          expect(textRect.left, greaterThanOrEqualTo(buttonRect.left));
          expect(textRect.right, lessThanOrEqualTo(buttonRect.right));
          await tester.tap(text);
        }
        expect(completions, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final chain in ['Solana', 'Ethereum']) {
      testWidgets('explicit paste fills a hidden $chain key in $language', (
        tester,
      ) async {
        const fixture =
            '0000000000000000000000000000000000000000000000000000000000000001';
        var reads = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return {'text': fixture};
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _pumpImport(tester, language: language);
        if (chain == 'Ethereum') {
          await tester.tap(find.text('Ethereum'));
          await tester.pumpAndSettle();
        }
        expect(reads, 0, reason: 'Clipboard access requires a user action');
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('private-key-paste')),
            matching: find.byIcon(Icons.copy),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('private-key-paste')));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('private-key-input')),
        );
        expect(field.controller!.text, fixture);
        expect(field.obscureText, isTrue);
        expect(reads, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'empty clipboard keeps the existing key and reports the problem',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': ''} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpImport(tester);
      await tester.enterText(
        find.byKey(const ValueKey('private-key-input')),
        'public-test-fixture',
      );
      await tester.tap(find.byKey(const ValueKey('private-key-paste')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('private-key-input')))
            .controller!
            .text,
        'public-test-fixture',
      );
      expect(find.text('Clipboard is empty'), findsOneWidget);
    },
  );

  testWidgets('clipboard permission errors never show clipboard contents', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          throw PlatformException(
            code: 'denied',
            message: 'secret-must-not-be-shown',
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpImport(tester);
    await tester.tap(find.byKey(const ValueKey('private-key-paste')));
    await tester.pumpAndSettle();
    expect(find.text('Unable to access the clipboard.'), findsOneWidget);
    expect(find.textContaining('secret-must-not-be-shown'), findsNothing);
  });

  testWidgets('late clipboard response does not replace manually edited text', (
    tester,
  ) async {
    final clipboard = Completer<Map<String, dynamic>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? await clipboard.future : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpImport(tester);
    await tester.tap(find.byKey(const ValueKey('private-key-paste')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('private-key-input')),
      'new-public-fixture',
    );
    clipboard.complete({'text': 'old-public-fixture'});
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('private-key-input')))
          .controller!
          .text,
      'new-public-fixture',
    );
  });

  testWidgets('import form fits an iPhone SE and switches key formats', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(750, 1334);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final created = DateTime.utc(2026, 1, 1);
    final solanaWallet = Wallet(
      id: 'sol',
      name: 'Main',
      curve: 'ed25519',
      threshold: 1,
      gen: 0,
      pubkey: '',
      chaincode: '',
      created: created,
      modified: created,
      keys: const [],
    );
    final ethereumWallet = Wallet(
      id: 'eth',
      name: 'Main',
      curve: 'secp256k1',
      threshold: 1,
      gen: 0,
      pubkey: '',
      chaincode: '',
      created: created,
      modified: created,
      keys: const [],
    );
    final secondWallet = Wallet(
      id: 'second-sol',
      name: 'Secondary',
      curve: 'ed25519',
      threshold: 1,
      gen: 0,
      pubkey: '',
      chaincode: '',
      created: created,
      modified: created,
      keys: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: InAppImportPrivateKeyScreen(
          groups: [
            LogicalWallet([solanaWallet, ethereumWallet]),
            LogicalWallet([secondWallet]),
          ],
          target: const UnifiedAccount(
            backend: AccountBackend.inapp,
            chain: 'solana',
            address: 'SolanaAddress',
            label: 'Main - Account 1',
            walletId: 'sol',
            accountId: 'sol-account',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Import account'), findsOneWidget);
    expect(find.text('Solana private key'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wallet-selector-trigger')));
    await tester.pumpAndSettle();
    final triggerBottom = tester
        .getBottomLeft(find.byKey(const Key('wallet-selector-trigger')))
        .dy;
    final optionsTop = tester
        .getTopLeft(find.byKey(const Key('wallet-selector-options')))
        .dy;
    expect(optionsTop, greaterThan(triggerBottom));
    await tester.tap(find.text('Secondary'));
    await tester.pumpAndSettle();
    expect(find.text('Secondary'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    final visibleKeyField = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    expect(visibleKeyField.expands, isTrue);
    expect(visibleKeyField.maxLines, isNull);

    await tester.tap(find.text('Ethereum'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ethereum private key'), findsOneWidget);
    expect(find.text('MPC password'), findsNothing);
    expect(find.text('Confirm password'), findsNothing);
    expect(find.textContaining('2FA recovery'), findsNothing);
  });

  testWidgets('standalone import is available without an existing wallet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const InAppImportPrivateKeyScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Import account'), findsOneWidget);
    expect(find.text('Wallet'), findsNothing);
    expect(find.text('Solana private key'), findsOneWidget);
  });
}
