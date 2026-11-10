import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/main.dart';
import 'package:tibaneapp/screens/browser/dapp_browser_screen.dart';
import 'package:tibaneapp/screens/settings/wallets_accounts_screen.dart';
import 'package:tibaneapp/screens/settings_screen.dart';
import 'package:tibaneapp/screens/tools_screen.dart';
import 'package:tibaneapp/screens/wallet/biometric_migration_screen.dart';
import 'package:tibaneapp/screens/wallet/wallet_welcome_screen.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet/biometric_migration_reminder.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';
import 'package:tibaneapp/widgets/wallet_button.dart';

const _native = UnifiedAccount(
  backend: AccountBackend.inapp,
  chain: 'solana',
  address: 'public-native-account-address',
  label: 'Native',
  accountId: 'native',
  walletId: 'wallet',
);
const _external = UnifiedAccount(
  backend: AccountBackend.mwa,
  chain: 'solana',
  address: 'public-external-account-address',
  label: 'External',
);

class _Backend extends LibwalletBackend {
  bool exists = false;
  bool migrationPending = false;
  bool migrationSucceeds = true;
  int migrationCalls = 0;
  @override
  bool get hasWallet => exists;
  @override
  Future<bool> needsBiometricMigration() async => migrationPending;
  @override
  Future<bool> migrateToBiometricV1() async {
    migrationCalls++;
    if (migrationSucceeds) migrationPending = false;
    return migrationSucceeds;
  }
}

class _Wallet extends WalletService {
  final backend = _Backend();
  bool connected = false;
  bool connecting = false;
  List<UnifiedAccount> entries = [];
  UnifiedAccount? selected;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  bool get dataReady => true;
  @override
  bool get isConnected => connected;
  @override
  bool get isConnecting => connecting;
  @override
  List<UnifiedAccount> get accounts => entries;
  @override
  UnifiedAccount? get currentAccount =>
      selected ?? (entries.isEmpty ? null : entries.first);
  @override
  String? get publicKey => currentAccount?.address;
  @override
  Future<void> reportLifecycle(String status) async {}
  @override
  Future<bool> setCurrentAccount(
    UnifiedAccount account, {
    String? networkId,
  }) async {
    selected = account;
    backend.exists = true;
    connected = true;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester,
  _Wallet wallet, {
  bool shell = false,
  Locale locale = const Locale('en'),
}) async {
  final compliance = UkComplianceService();
  addTearDown(compliance.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>.value(value: wallet),
        ChangeNotifierProvider<UkComplianceService>.value(value: compliance),
      ],
      child: MaterialApp(
        locale: locale,
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: shell
            ? const TibaneShell(forceSeeker: false)
            : const Scaffold(body: WalletButton()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(Scaffold).first));
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async => null);
    }
  });
  tearDown(() {
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  test(
    'biometric reminder is due exactly seven days after deferring',
    () async {
      final now = DateTime.utc(2026);
      expect(await BiometricMigrationReminder.isDue(now: now), isTrue);
      await BiometricMigrationReminder.defer(dontShowAgain: false, now: now);
      expect(
        await BiometricMigrationReminder.isDue(
          now: now.add(
            const Duration(days: 7) - const Duration(milliseconds: 1),
          ),
        ),
        isFalse,
      );
      expect(
        await BiometricMigrationReminder.isDue(
          now: now.add(const Duration(days: 7)),
        ),
        isTrue,
      );
    },
  );

  testWidgets('Not now skips without migrating and reappears only when due', (
    tester,
  ) async {
    final wallet = _Wallet();
    wallet.backend.migrationPending = true;
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet, shell: true);
    expect(find.byType(BiometricMigrationScreen), findsOneWidget);
    await tester.tap(find.text(l10n.bioMigNotNow));
    await tester.pumpAndSettle();
    expect(wallet.backend.migrationCalls, 0);
    expect(find.byType(WalletWelcomeScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, wallet, shell: true);
    expect(find.byType(BiometricMigrationScreen), findsNothing);

    await BiometricMigrationReminder.defer(
      dontShowAgain: false,
      now: DateTime.now().subtract(const Duration(days: 8)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, wallet, shell: true);
    expect(find.byType(BiometricMigrationScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('checking Never show again only takes effect after Not now', (
    tester,
  ) async {
    final wallet = _Wallet();
    wallet.backend.migrationPending = true;
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet, shell: true);
    await tester.tap(find.text(l10n.bioMigDontShowAgain));
    await tester.pumpAndSettle();
    expect(await BiometricMigrationReminder.isDue(), isTrue);
    await tester.tap(find.text(l10n.bioMigNotNow));
    await tester.pumpAndSettle();
    expect(wallet.backend.migrationCalls, 0);
    expect(
      await BiometricMigrationReminder.isDue(now: DateTime.utc(2099)),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, wallet, shell: true);
    expect(find.byType(BiometricMigrationScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('protecting keys dismisses the prompt only on success', (
    tester,
  ) async {
    final wallet = _Wallet();
    wallet.backend
      ..migrationPending = true
      ..migrationSucceeds = false;
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet, shell: true);
    await tester.tap(find.text(l10n.bioMigButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.bioMigPartialError), findsOneWidget);
    expect(await BiometricMigrationReminder.isDue(), isTrue);

    wallet.backend.migrationSucceeds = true;
    await tester.tap(find.text(l10n.bioMigButton));
    await tester.pumpAndSettle();
    expect(wallet.backend.migrationCalls, 2);
    expect(find.byType(WalletWelcomeScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, wallet, shell: true);
    expect(find.byType(BiometricMigrationScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('$locale biometric actions fit on a compact screen', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wallet = _Wallet();
      wallet.backend.migrationPending = true;
      addTearDown(wallet.dispose);
      final l10n = await _pump(tester, wallet, shell: true, locale: locale);
      final primary = find.text(l10n.bioMigButton);
      final skip = find.text(l10n.bioMigNotNow);
      final checkbox = find.text(l10n.bioMigDontShowAgain);
      expect(
        tester.getBottomLeft(primary).dy,
        lessThan(tester.getTopLeft(skip).dy),
      );
      expect(
        tester.getBottomLeft(skip).dy,
        lessThan(tester.getTopLeft(checkbox).dy),
      );
      await tester.ensureVisible(skip);
      await tester.pumpAndSettle();
      expect(skip.hitTestable(), findsOneWidget);
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      expect(checkbox.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$locale starts on Wallet with only four footer tabs', (
      tester,
    ) async {
      final wallet = _Wallet();
      addTearDown(wallet.dispose);
      final l10n = await _pump(tester, wallet, shell: true, locale: locale);
      final nav = tester.widget<BottomNavigationBar>(
        find.byType(BottomNavigationBar),
      );
      expect(nav.currentIndex, 0);
      expect(nav.items.map((item) => item.label), [
        l10n.bottomNavWalletLabel,
        l10n.dashboardTabActivity,
        l10n.bottomNavBrowseLabel,
        l10n.bottomNavSettingsLabel,
      ]);
      expect(find.text(l10n.bottomNavHomeLabel), findsNothing);
      expect(find.text(l10n.actionConnect), findsNothing);
      expect(find.byType(WalletWelcomeScreen), findsOneWidget);
      expect(find.byType(DAppBrowserScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('Wallet and Settings keep their correctly indexed stacks', (
    tester,
  ) async {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet, shell: true);
    final footer = find.byType(BottomNavigationBar);
    Future<void> tab(String label) async {
      await tester.tap(find.descendant(of: footer, matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    await tab(l10n.bottomNavSettingsLabel);
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.text(l10n.settingsWalletsAccountsTitle));
    await tester.pumpAndSettle();
    expect(find.byType(WalletsAccountsScreen), findsOneWidget);
    await tab(l10n.bottomNavWalletLabel);
    expect(find.byType(WalletWelcomeScreen), findsOneWidget);
    await tab(l10n.bottomNavSettingsLabel);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(WalletsAccountsScreen), findsNothing);
    expect(find.byType(DAppBrowserScreen), findsNothing);
    tester.state<TibaneShellState>(find.byType(TibaneShell)).navigateTo(4);
    await tester.pumpAndSettle();
    expect(tester.widget<BottomNavigationBar>(footer).currentIndex, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('Connect is hidden with no saved or connected wallet', (
    tester,
  ) async {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    await _pump(tester, wallet);
    expect(find.text('Connect'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    wallet.entries = [_external];
    wallet.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('Settings opens Tools without losing the four-tab footer', (
    tester,
  ) async {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet, shell: true);
    final footer = find.byType(BottomNavigationBar);
    await tester.tap(
      find.descendant(
        of: footer,
        matching: find.text(l10n.bottomNavSettingsLabel),
      ),
    );
    await tester.pumpAndSettle();
    final tools = find.byKey(const Key('settings-tools'));
    await tester.ensureVisible(tools);
    await tester.tap(tools);
    await tester.pumpAndSettle();
    expect(find.byType(ToolsScreen), findsOneWidget);
    expect(tester.widget<BottomNavigationBar>(footer).items, hasLength(4));
    expect(find.byKey(const Key('tools-stake')), findsOneWidget);
    expect(find.byKey(const Key('tools-incinerator')), findsOneWidget);
    expect(find.byKey(const Key('tools-search')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('saved in-app wallets retain the reconnect action', (
    tester,
  ) async {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    wallet.backend.exists = true;
    await _pump(tester, wallet);
    expect(find.text('Connect'), findsOneWidget);
    wallet.backend.exists = false;
    wallet.entries = [_native];
    wallet.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Connect opens a saved inactive wallet instead of onboarding', (
    tester,
  ) async {
    final wallet = _Wallet()..entries = [_native];
    addTearDown(wallet.dispose);
    final l10n = await _pump(tester, wallet);
    expect(wallet.backend.hasWallet, isFalse);
    await tester.tap(find.text(l10n.actionConnect));
    await tester.pumpAndSettle();
    expect(find.text(l10n.walletButtonInAppWalletCreate), findsNothing);
    await tester.tap(find.text(l10n.walletButtonInAppWalletName));
    await tester.pumpAndSettle();
    expect(wallet.selected, _native);
    expect(wallet.backend.hasWallet, isTrue);
    expect(find.byType(WalletWelcomeScreen), findsNothing);
    expect(find.text(l10n.actionConnect), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final account in [_native, _external]) {
    testWidgets('${account.backend.name} connected selector remains visible', (
      tester,
    ) async {
      final wallet = _Wallet();
      addTearDown(wallet.dispose);
      wallet.connected = true;
      wallet.entries = [account];
      await _pump(tester, wallet);
      expect(find.text('Connect'), findsNothing);
      expect(find.text('publ...ress'), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connection progress is still shown while connecting', (
    tester,
  ) async {
    final wallet = _Wallet();
    addTearDown(wallet.dispose);
    wallet.connecting = true;
    final compliance = UkComplianceService();
    addTearDown(compliance.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WalletService>.value(
        value: wallet,
        child: MaterialApp(
          theme: TibaneTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: WalletButton()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });
}
