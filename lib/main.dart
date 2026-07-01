import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:provider/provider.dart';

import 'constants/solana_constants.dart';
import 'screens/browser/dapp_browser_screen.dart';
import 'screens/clawdwallet/pairing_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/swap_screen.dart';
import 'screens/wallet/biometric_migration_screen.dart';
import 'screens/wallet/wallet_screen.dart';
import 'services/browser_preferences.dart';
import 'services/favorites_service.dart';
import 'services/uk_compliance_service.dart';
import 'services/wallet_service.dart';
import 'theme/tibane_theme.dart';
import 'widgets/cat_logo.dart';
import 'widgets/network_chip.dart';
import 'widgets/wallet_button.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Dark status bar for the dark theme
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: TibaneColors.dark,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Lock to portrait only
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const TibaneApp());
}

/// Root navigator key — used by the deep-link listener to push the
/// pairing screen without needing a `BuildContext`.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Whether the startup gate (D16) can reveal the app instead of the loading
/// splash. Pending until the biometric-migration check resolves; then reveal
/// immediately when migration is needed (its screen comes next), otherwise wait
/// for the first wallet-data snapshot. Pure, for unit testing.
@visibleForTesting
bool startupGateReady({
  required bool? needsMigration,
  required bool walletDataReady,
}) {
  if (needsMigration == null) return false;
  if (needsMigration) return true;
  return walletDataReady;
}

class TibaneApp extends StatelessWidget {
  const TibaneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WalletService()..tryRestore()),
        ChangeNotifierProvider(create: (_) => FavoritesService()..load()),
        ChangeNotifierProvider(create: (_) => BrowserPreferences()..load()),
        ChangeNotifierProvider(create: (_) => UkComplianceService()..init()),
      ],
      child: MaterialApp(
        title: 'Tibane',
        debugShowCheckedModeBanner: false,
        theme: TibaneTheme.darkTheme,
        navigatorKey: rootNavigatorKey,
        // PhoneFieldLocalization powers the phone_form_field country
        // picker labels and validator error messages.
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          ...PhoneFieldLocalization.delegates,
        ],
        supportedLocales: const [Locale('en')],
        home: const TibaneShell(),
      ),
    );
  }
}

/// Main app shell with bottom navigation
class TibaneShell extends StatefulWidget {
  /// Tab to show on first build. 0=home, 1=wallet/swap, 2=browse, 3=settings.
  /// Staking and Agents live behind route pushes (Home card / Settings tile).
  final int initialIndex;

  /// When non-null, forces the Seeker / non-Seeker layout instead of probing
  /// MWA. `false` selects the Wallet tab; `true` selects the Swap tab.
  final bool? forceSeeker;

  const TibaneShell({super.key, this.initialIndex = 0, this.forceSeeker});

  @override
  State<TibaneShell> createState() => TibaneShellState();
}

class TibaneShellState extends State<TibaneShell>
    with WidgetsBindingObserver {
  late int _currentIndex = widget.initialIndex;

  /// The Browse tab (dApp webview) is built lazily: its heavy platform-view /
  /// RenderThread only spins up once the user first opens Browse, not at
  /// startup. Once visited it stays alive in the IndexedStack, but is paused
  /// (WebViewWidget detached) whenever another tab is active — see
  /// [DAppBrowserScreen.active].
  late bool _browserVisited = widget.initialIndex == 2;

  /// Null while checking; true shows the mandatory biometric-migration screen
  /// (Phase 3 / D7); false renders the normal home.
  bool? _needsMigration;

  /// Startup splash backstop (D16): reveal even if the wallet snapshot never
  /// lands (e.g. RPC down), so the app never hangs on the splash.
  bool _splashTimedOut = false;
  Timer? _splashTimeout;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _splashTimeout = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _splashTimedOut = true);
    });
    _initDeepLinks();
    _checkBiometricMigration();
  }

  Future<void> _checkBiometricMigration() async {
    final need =
        await context.read<WalletService>().libwallet.needsBiometricMigration();
    if (!mounted) return;
    setState(() => _needsMigration = need);
  }

  // Report foreground/background to libwallet so its pollers pause off-screen
  // and resume-poll immediately on foreground (Gap 4). libwallet defaults to
  // active, so we only need the transitions — no initial report. `inactive`
  // is transient (iOS app-switcher / notification shade), so we skip it to
  // avoid thrashing the poller.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final status = switch (state) {
      AppLifecycleState.resumed => 'foreground',
      AppLifecycleState.paused ||
      AppLifecycleState.detached ||
      AppLifecycleState.hidden => 'background',
      AppLifecycleState.inactive => null,
    };
    if (status != null) {
      unawaited(context.read<WalletService>().reportLifecycle(status));
    }
  }

  Future<void> _initDeepLinks() async {
    // Cold start: app launched FROM the URL.
    final initial = await _appLinks.getInitialLink();
    if (initial != null) _handleIncomingUri(initial);

    // Warm: app already running, new intent arrives (singleTop).
    _linkSub = _appLinks.uriLinkStream.listen(
      _handleIncomingUri,
      onError: (e) => debugPrint('deep link stream error: $e'),
    );
  }

  void _handleIncomingUri(Uri uri) {
    // Only act on the pairing scheme we registered; anything else is a
    // stray intent and should be ignored.
    if (uri.scheme != 'tibane' || uri.host != 'pair') return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(builder: (_) => PairingScreen(url: uri.toString())),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    _splashTimeout?.cancel();
    super.dispose();
  }

  /// Switch the active bottom-nav tab. Public for screenshot orchestration.
  void navigateTo(int index) => _navigateTo(index);

  void _navigateTo(int index) {
    setState(() {
      _currentIndex = index;
      if (index == 2) _browserVisited = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Startup loading gate (D16): hold a branded splash until the migration
    // check resolves AND the first wallet-data snapshot lands (or there's no
    // wallet, or the timeout fires). WalletService is the single libwallet
    // listener and owns `dataReady`; the shell just reads it here.
    final wallet = context.watch<WalletService>();
    if (!startupGateReady(
      needsMigration: _needsMigration,
      walletDataReady: wallet.dataReady || _splashTimedOut,
    )) {
      return const _StartupSplash();
    }

    // Mandatory one-time biometric migration (Phase 3 / D7) gates the home.
    if (_needsMigration == true) {
      return BiometricMigrationScreen(
        onDone: () => setState(() => _needsMigration = false),
      );
    }
    // The app's mode follows the CURRENT ACCOUNT's backend: an MWA / Seed Vault
    // account shows the swap-first (external) layout; an in-app MPC account (or
    // no account yet) shows the Wallet dashboard. So switching accounts switches
    // the whole mode. forceSeeker overrides for the screenshot harness; UK users
    // never get the Swap tab.
    final isUk = context.watch<UkComplianceService>().isUk;
    final showSwap =
        (widget.forceSeeker ?? (wallet.currentAccount?.isMwa ?? false)) && !isUk;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        backgroundColor: TibaneColors.black,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 56,
        title: Row(
          children: [
            const CatLogo(size: 28),
            const SizedBox(width: 10),
            Text(
              'Tibane',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 8),
            const NetworkChip(),
          ],
        ),
        actions: const [WalletButton(), SizedBox(width: 12)],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(onNavigate: _navigateTo),
          // Tab 2 follows the current account's mode: Swap for an MWA account,
          // the Wallet dashboard for an in-app MPC account (or no account).
          showSwap
              ? const SwapScreen(initialInputMint: wsolMint)
              : const WalletScreen(),
          // Browse: constructed only after its first visit, and its webview is
          // detached (paused) while another tab is active so the native
          // RenderThread doesn't keep compositing off-screen.
          _browserVisited
              ? DAppBrowserScreen(active: _currentIndex == 2)
              : const SizedBox.shrink(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: TibaneColors.border)),
        ),
        child: Builder(
          builder: (context) {
            return BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: _navigateTo,
              items: [
                const BottomNavigationBarItem(
                  icon: Icon(Icons.home_outlined),
                  activeIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(
                    showSwap
                        ? Icons.swap_horiz_outlined
                        : Icons.account_balance_wallet_outlined,
                  ),
                  activeIcon: Icon(
                    showSwap ? Icons.swap_horiz : Icons.account_balance_wallet,
                  ),
                  label: showSwap ? 'Swap' : 'Wallet',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.travel_explore_outlined),
                  activeIcon: Icon(Icons.travel_explore),
                  label: 'Browse',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.settings_outlined),
                  activeIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Branded startup loading screen (D16) shown until wallet data is ready, so
/// the user never sees the cold-start `0`-balance flash before the snapshot
/// lands. See `startupGateReady` + `WalletService.dataReady`.
class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CatLogo(size: 84, glow: true),
            const SizedBox(height: 24),
            Text(
              'Tibane Labs',
              style: monoStyle(fontSize: 13, color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: TibaneColors.orange,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
