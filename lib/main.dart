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
import 'screens/wallet/wallet_screen.dart';
import 'services/favorites_service.dart';
import 'services/mwa_detector.dart';
import 'services/uk_compliance_service.dart';
import 'services/wallet_service.dart';
import 'theme/tibane_theme.dart';
import 'widgets/cat_logo.dart';
import 'widgets/network_chip.dart';
import 'widgets/wallet_button.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Dark status bar for the dark theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: TibaneColors.dark,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Lock to portrait only
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const TibaneApp());
}

/// Root navigator key — used by the deep-link listener to push the
/// pairing screen without needing a `BuildContext`.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class TibaneApp extends StatelessWidget {
  const TibaneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WalletService()..tryRestore()),
        ChangeNotifierProvider(create: (_) => FavoritesService()..load()),
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

class TibaneShellState extends State<TibaneShell> {
  late int _currentIndex = widget.initialIndex;
  late bool _isSeekerDevice = widget.forceSeeker ?? false;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    if (widget.forceSeeker == null) {
      hasMwaWallet().then((v) {
        if (mounted) setState(() => _isSeekerDevice = v);
      });
    }
    _initDeepLinks();
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
    nav.push(MaterialPageRoute(
      builder: (_) => PairingScreen(url: uri.toString()),
    ));
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  /// Switch the active bottom-nav tab. Public for screenshot orchestration.
  void navigateTo(int index) => _navigateTo(index);

  void _navigateTo(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
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
        actions: const [
          WalletButton(),
          SizedBox(width: 12),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(onNavigate: _navigateTo),
          // UK users never see a Swap tab — they get the wallet view in
          // its place. Non-UK users on Seeker keep the Swap default.
          (_isSeekerDevice && !context.watch<UkComplianceService>().isUk)
              ? const SwapScreen(initialInputMint: wsolMint)
              : const WalletScreen(),
          const DAppBrowserScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: TibaneColors.border),
          ),
        ),
        child: Builder(builder: (context) {
          final isUk = context.watch<UkComplianceService>().isUk;
          final showSwap = _isSeekerDevice && !isUk;
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
                icon: Icon(showSwap
                    ? Icons.swap_horiz_outlined
                    : Icons.account_balance_wallet_outlined),
                activeIcon: Icon(showSwap
                    ? Icons.swap_horiz
                    : Icons.account_balance_wallet),
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
        }),
      ),
    );
  }
}
