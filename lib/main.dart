import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
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
import 'services/balances_store.dart';
import 'services/browser_preferences.dart';
import 'services/favorites_service.dart';
import 'services/uk_compliance_service.dart';
import 'services/wallet_service.dart';
import 'theme/tibane_theme.dart';
import 'widgets/cat_logo.dart';
import 'widgets/tibane_app_bar.dart';

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

/// What a system back-press does from the shell (D-nav-3). With per-tab
/// Navigators, back pops the active tab's stack when it has one; at a tab root
/// there's nothing to pop, so the app closes — matching the pre-migration
/// behaviour where back on a root tab exited. Pure, for unit testing.
enum ShellBackAction { popTab, exitApp }

@visibleForTesting
ShellBackAction shellBackAction({required bool activeTabCanPop}) =>
    activeTabCanPop ? ShellBackAction.popTab : ShellBackAction.exitApp;

/// Lazy-build + pause state for the Browse tab, given whether it was already
/// built (`wasVisited`) and the active tab index. The heavy webview is built
/// only once the tab is first opened (`visited`), then stays alive but paused
/// (`active` false) whenever another tab is showing. Pure, for unit testing.
@visibleForTesting
({bool visited, bool active}) browserTabState({
  required bool wasVisited,
  required int activeIndex,
}) {
  final active = activeIndex == 2;
  return (visited: wasVisited || active, active: active);
}

class TibaneApp extends StatelessWidget {
  const TibaneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WalletService()..tryRestore()),
        // Centralized holdings + tx store; reads WalletService (listed first so
        // it's resolvable here). See BALANCES_STORE_MIGRATION.md.
        ChangeNotifierProvider(
          create: (ctx) => BalancesStore(ctx.read<WalletService>())..init(),
        ),
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

class TibaneShellState extends State<TibaneShell> with WidgetsBindingObserver {
  late int _currentIndex = widget.initialIndex;

  /// One [Navigator] per bottom-nav tab, so pushes stay inside the active tab
  /// and the [BottomNavigationBar] remains visible on pushed screens (Swap,
  /// token/staking detail, settings sub-screens). See NAVIGATION_MIGRATION.md.
  final List<GlobalKey<NavigatorState>> _navKeys =
      List.generate(4, (_) => GlobalKey<NavigatorState>());

  /// The active tab index, exposed to the lazily-built Browse tab so its
  /// webview pauses/resumes (via [DAppBrowserScreen.active]) as tabs change.
  /// The tab's Navigator root is built once, so it can't read [_currentIndex]
  /// directly — it listens to this instead. See [_BrowserTab].
  late final ValueNotifier<int> _activeTab = ValueNotifier<int>(
    widget.initialIndex,
  );

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
    final need = await context
        .read<WalletService>()
        .libwallet
        .needsBiometricMigration();
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
    _activeTab.dispose();
    super.dispose();
  }

  /// Switch the active bottom-nav tab. Public for screenshot orchestration.
  void navigateTo(int index) => _navigateTo(index);

  void _navigateTo(int index) {
    setState(() => _currentIndex = index);
    _activeTab.value = index;
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
    // Hide the bottom nav while the keyboard is up so it doesn't float above
    // it — the bar lives on the shell Scaffold, outside the tab Navigators.
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return PopScope(
      // The tab Navigators sit below the root navigator, so a system back must
      // be routed to the active tab's Navigator first; only when it has nothing
      // to pop do we let the app close (matching the pre-migration behaviour
      // where back on a root tab exited).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navKeys[_currentIndex].currentState;
        switch (shellBackAction(activeTabCanPop: nav?.canPop() ?? false)) {
          case ShellBackAction.popTab:
            nav!.pop();
          case ShellBackAction.exitApp:
            SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        body: IndexedStack(
          index: _currentIndex,
          children: [
            _TabNavigator(
              navKey: _navKeys[0],
              rootBuilder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: const TibaneAppBar(),
                body: HomeScreen(onNavigate: _navigateTo),
              ),
            ),
            // Tab 1 follows the current account's mode: Swap for an MWA account,
            // the Wallet dashboard for an in-app MPC account (or no account).
            // The selection lives in [_WalletOrSwapTab] so this Navigator's
            // root stays stable when the account (and thus the mode) changes.
            _TabNavigator(
              navKey: _navKeys[1],
              rootBuilder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: const TibaneAppBar(),
                body: _WalletOrSwapTab(forceSeeker: widget.forceSeeker),
              ),
            ),
            // Browse: built (and its heavy webview spun up) only after its first
            // visit, and paused while another tab is active — see [_BrowserTab].
            _TabNavigator(
              navKey: _navKeys[2],
              rootBuilder: (_) => Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: const TibaneAppBar(),
                body: _BrowserTab(activeTab: _activeTab),
              ),
            ),
            _TabNavigator(
              navKey: _navKeys[3],
              rootBuilder: (_) => const Scaffold(
                backgroundColor: TibaneColors.black,
                appBar: TibaneAppBar(),
                body: SettingsScreen(),
              ),
            ),
          ],
        ),
        bottomNavigationBar: keyboardOpen ? null : _bottomNav(showSwap),
      ),
    );
  }

  Widget _bottomNav(bool showSwap) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TibaneColors.border)),
      ),
      child: BottomNavigationBar(
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

/// Wraps a single bottom-nav tab in its own [Navigator] so pushes stay inside
/// the tab and the shell's [BottomNavigationBar] stays visible. The tab's root
/// screen is [rootBuilder]; detail screens push on top of it within this
/// Navigator. Kept alive across tab switches by the shell's [IndexedStack].
class _TabNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navKey;
  final WidgetBuilder rootBuilder;

  const _TabNavigator({required this.navKey, required this.rootBuilder});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navKey,
      onGenerateRoute: (settings) =>
          MaterialPageRoute(builder: rootBuilder, settings: settings),
    );
  }
}

/// Tab-1 root. Renders Swap for an MWA / Seed Vault account (and not in the UK)
/// or the Wallet dashboard otherwise, watching the providers itself so the tab
/// Navigator's root stays stable when the account switches. Mirrors the shell's
/// `showSwap` logic; [forceSeeker] overrides it for the screenshot harness.
class _WalletOrSwapTab extends StatelessWidget {
  final bool? forceSeeker;

  const _WalletOrSwapTab({this.forceSeeker});

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final isUk = context.watch<UkComplianceService>().isUk;
    final showSwap =
        (forceSeeker ?? (wallet.currentAccount?.isMwa ?? false)) && !isUk;
    return showSwap
        ? const SwapScreen(initialInputMint: wsolMint)
        : const WalletScreen();
  }
}

/// Tab-2 root. Builds the heavy dApp browser lazily (only after the tab's first
/// visit) and forwards an `active` flag so the webview pauses while another tab
/// is showing. Reads tab changes from [activeTab] because this Navigator root
/// is built once and can't watch the shell's `_currentIndex` directly.
class _BrowserTab extends StatefulWidget {
  final ValueListenable<int> activeTab;

  const _BrowserTab({required this.activeTab});

  @override
  State<_BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends State<_BrowserTab> {
  late ({bool visited, bool active}) _state;

  @override
  void initState() {
    super.initState();
    _state = browserTabState(
      wasVisited: false,
      activeIndex: widget.activeTab.value,
    );
    widget.activeTab.addListener(_onTab);
  }

  void _onTab() {
    final next = browserTabState(
      wasVisited: _state.visited,
      activeIndex: widget.activeTab.value,
    );
    if (next != _state) setState(() => _state = next);
  }

  @override
  void dispose() {
    widget.activeTab.removeListener(_onTab);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_state.visited) return const SizedBox.shrink();
    return DAppBrowserScreen(active: _state.active);
  }
}
