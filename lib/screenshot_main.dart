/// Screenshot mode entry point.
///
/// Drives the *real* app screens with synthetic state. Mock services are
/// installed at the boundary (`RpcService.testInstance`, `ChiefStakerApi
/// .testInstance`, a stub `WalletService` + `LibwalletBackend`) and the
/// rest of the app — `TibaneShell`, `HomeScreen`, `WalletDashboard`,
/// `ReceiveScreen`, `StakingPoolsScreen`, `StakingDetailScreen`,
/// `IncineratorScreen`, `TokenDetailScreen` — runs unchanged.
///
/// Usage:
///   ./scripts/take_screenshots.sh              # iOS Simulator
///   ./scripts/take_screenshots_android.sh      # Android emulator
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'main.dart';
import 'models/staking_pool.dart';
import 'models/token_account.dart';
import 'screens/incinerator_screen.dart';
import 'screens/staking/staking_detail_screen.dart';
import 'screens/staking/staking_pools_screen.dart';
import 'screens/token_detail_screen.dart';
import 'services/chiefstaker_api.dart';
import 'services/favorites_service.dart';
import 'services/rpc_service.dart';
import 'services/wallet/libwallet_backend.dart';
import 'services/wallet/wallet_backend.dart';
import 'services/wallet_service.dart';
import 'theme/tibane_theme.dart';

// ---------------------------------------------------------------------------
// Demo state
// ---------------------------------------------------------------------------

const _demoAddress = '8C9p8mE7BqcyaKxrJfwwa44Ny2t76YqBxQVbgbA6taTp';
const _chiefPussyMint = 'DRtvTCzfiKGhCVREmBbZdN9sB8PHeq9KdRZ3VmFhpump';
const _poolAddress = 'C4poo1ChiefStaker11111111111111111111111111';
const _poolVault = 'V4uLT1ChiefStaker111111111111111111111111';
const _poolAuthority = 'AuTHorIty11111111111111111111111111111111';

// 2.4831 SOL in lamports
final BigInt _solBalance = BigInt.from(2483100000);
// 128,540 $CP at 6 decimals
final BigInt _chiefPussyBalance = BigInt.from(128540) * BigInt.from(1000000);

// ---------------------------------------------------------------------------
// Signal coordination (precise on iOS, timing on Android)
// ---------------------------------------------------------------------------

const _signalDir = '/tmp/screenshot_signals';

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

void _cleanupSignals() {
  if (_isAndroid) return;
  try {
    final dir = Directory(_signalDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

Future<void> _signalReady(int n) async {
  if (_isAndroid) {
    debugPrint('SCREENSHOT_SIGNAL: Screen $n ready (Android - timing mode)');
    return;
  }
  final dir = Directory(_signalDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  await File(
    '$_signalDir/ready_$n',
  ).writeAsString(DateTime.now().toIso8601String());
  debugPrint('SCREENSHOT_SIGNAL: Screen $n ready');
}

Future<void> _waitForCapture(int n) async {
  if (_isAndroid) {
    await Future<void>.delayed(const Duration(seconds: 7));
    return;
  }
  final f = File('$_signalDir/ready_$n');
  for (var i = 0; i < 600; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!f.existsSync()) {
      debugPrint('SCREENSHOT_SIGNAL: Screen $n captured');
      return;
    }
  }
  debugPrint('SCREENSHOT_SIGNAL: Timeout waiting for capture of screen $n');
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: TibaneColors.dark,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Install service stubs before any screen constructs the real ones.
  RpcService.testInstance = _StubRpcService();
  ChiefStakerApi.testInstance = _StubChiefStakerApi();

  _cleanupSignals();
  runApp(const _ScreenshotApp());
}

final _shellKey = GlobalKey<TibaneShellState>();
final _navKey = GlobalKey<NavigatorState>();

class _ScreenshotApp extends StatelessWidget {
  const _ScreenshotApp();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<WalletService>(
          create: (_) => _StubWalletService(),
        ),
        ChangeNotifierProvider<FavoritesService>(
          create: (_) => FavoritesService()..load(),
        ),
      ],
      child: MaterialApp(
        title: 'Tibane',
        debugShowCheckedModeBanner: false,
        theme: TibaneTheme.darkTheme,
        navigatorKey: _navKey,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: _ShellWithRunner(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Slideshow runner — mounts TibaneShell and walks through 7 screens
// ---------------------------------------------------------------------------

class _ShellWithRunner extends StatefulWidget {
  @override
  State<_ShellWithRunner> createState() => _ShellWithRunnerState();
}

class _ShellWithRunnerState extends State<_ShellWithRunner> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSequence());
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _captureAt(int n) async {
    await _signalReady(n);
    await _waitForCapture(n);
  }

  /// Push a route on the root navigator without awaiting (so we can capture
  /// while it's on-screen, then pop).
  void _push(Widget page) {
    _navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _pop() {
    final nav = _navKey.currentState!;
    if (nav.canPop()) nav.pop();
  }

  Future<void> _runSequence() async {
    // First frame mounted — give fonts/theme a moment to settle.
    await _wait(1500);

    // 1) Home
    _shellKey.currentState?.navigateTo(0);
    await _wait(900);
    await _captureAt(1);

    // 2) Wallet dashboard (tab index 1 since staking left the bottom nav)
    _shellKey.currentState?.navigateTo(1);
    await _wait(1500); // dashboard does Future.wait for assets+txs
    await _captureAt(2);

    // 3) Staking pools — now reached as a route push from Home, not a tab.
    _push(
      const Scaffold(
        backgroundColor: TibaneColors.black,
        body: SafeArea(child: StakingPoolsScreen()),
      ),
    );
    await _wait(1300); // ChiefStakerApi.listPools resolves quickly
    await _captureAt(3);
    _pop();
    await _wait(400);

    // 4) Staking detail (push real screen with our top mock pool)
    _push(StakingDetailScreen(pool: _mockTopPool()));
    await _wait(1500);
    await _captureAt(4);
    _pop();
    await _wait(400);

    // 5) Incinerator (the screen has its own header, so wrap without AppBar)
    _push(
      const Scaffold(
        backgroundColor: TibaneColors.black,
        body: SafeArea(child: IncineratorScreen()),
      ),
    );
    await _wait(2000);
    await _captureAt(5);
    _pop();
    await _wait(400);

    // 6) Token info — pushed with the $ChiefPussy mint. TokenDetailScreen
    // owns its own Scaffold + AppBar so no caller wrapping is needed.
    _push(const TokenDetailScreen(mint: _chiefPussyMint));
    await _wait(1800);
    await _captureAt(6);
    _pop();

    debugPrint('SCREENSHOT_SIGNAL: All screens captured');
  }

  @override
  Widget build(BuildContext context) {
    return TibaneShell(key: _shellKey, initialIndex: 0, forceSeeker: false);
  }
}

// ---------------------------------------------------------------------------
// Stub WalletService — pretends connected with the in-app wallet backend
// ---------------------------------------------------------------------------

class _StubWalletService extends WalletService {
  final _StubLibwallet _stubLib = _StubLibwallet();

  @override
  bool get isConnected => true;

  @override
  bool get isAuthenticated => true;

  @override
  bool get isConnecting => false;

  @override
  String? get publicKey => _demoAddress;

  @override
  String? get walletName => 'Tibane Wallet';

  @override
  WalletKind get kind => WalletKind.inapp;

  @override
  WalletBackend get active => _stubLib;

  @override
  LibwalletBackend get libwallet => _stubLib;

  @override
  BigInt get solBalance => _solBalance;

  @override
  BigInt get chiefPussyBalance => _chiefPussyBalance;

  @override
  String? get error => null;

  @override
  Future<void> tryRestore() async {}

  @override
  Future<void> refreshBalances() async {}

  @override
  Future<bool> connectMwa() async => false;

  @override
  Future<void> useLibwallet() async {}

  @override
  Future<void> disconnect() async {}
}

// ---------------------------------------------------------------------------
// Stub LibwalletBackend — exposes hasWallet + canned getAssets/Txs
// ---------------------------------------------------------------------------

class _StubLibwallet extends LibwalletBackend {
  @override
  bool get hasWallet => true;

  @override
  bool get isConnected => true;

  @override
  String? get publicKey => _demoAddress;

  @override
  String? get walletName => 'Tibane Wallet';

  @override
  bool get isConnecting => false;

  @override
  String? get error => null;

  @override
  Future<void> tryRestore() async {}

  @override
  Future<List<lw.Asset>> getAssets({String convert = 'USD'}) async {
    final now = DateTime.now();
    return [
      lw.Asset(
        id: 'a1',
        key: 'solana:SOL',
        name: 'Solana',
        symbol: 'SOL',
        amount: lw.Amount(_solBalance, 9),
        type: 'native',
        network: 'solana.mainnet',
        testNet: false,
        fiatAmount: lw.Amount(BigInt.from(59342), 2),
        fiatCurrency: 'USD',
        created: now,
        updated: now,
      ),
      lw.Asset(
        id: 'a2',
        key: 'solana:$_chiefPussyMint',
        name: 'Tibane Thecat',
        symbol: r'$ChiefPussy',
        amount: lw.Amount(_chiefPussyBalance, 6),
        type: 'spl-token',
        network: 'solana.mainnet',
        testNet: false,
        fiatAmount: lw.Amount(BigInt.from(4812), 2),
        fiatCurrency: 'USD',
        created: now,
        updated: now,
      ),
      lw.Asset(
        id: 'a3',
        key: 'solana:USDC',
        name: 'USD Coin',
        symbol: 'USDC',
        amount: lw.Amount(BigInt.from(14250) * BigInt.from(10000), 6),
        type: 'spl-token',
        network: 'solana.mainnet',
        testNet: false,
        fiatAmount: lw.Amount(BigInt.from(14250), 2),
        fiatCurrency: 'USD',
        created: now,
        updated: now,
      ),
      lw.Asset(
        id: 'a4',
        key: 'solana:JUP',
        name: 'Jupiter',
        symbol: 'JUP',
        amount: lw.Amount(BigInt.from(51230) * BigInt.from(10000), 6),
        type: 'spl-token',
        network: 'solana.mainnet',
        testNet: false,
        fiatAmount: lw.Amount(BigInt.from(28484), 2),
        fiatCurrency: 'USD',
        created: now,
        updated: now,
      ),
    ];
  }

  @override
  Future<List<lw.Transaction>> getTransactions({
    int limit = 50,
    String? forAddress,
    int maxPages = 5,
  }) async {
    final now = DateTime.now();
    DateTime ago(Duration d) => now.subtract(d);
    return [
      lw.Transaction(
        id: 't1',
        type: 'solana_transfer',
        asset: 'solana:SOL',
        from: _demoAddress,
        to: '7yQ3HZx9pnX7VuJh2ku4tNvfM8dRcXkWk2bVqwvK2x9p',
        gas: 0,
        nonce: 0,
        amount: lw.Amount(BigInt.from(250000000), 9),
        fiatAmount: lw.Amount(BigInt.from(5971), 2),
        fiatCurrency: 'USD',
        created: ago(const Duration(hours: 6, minutes: 47)),
      ),
      lw.Transaction(
        id: 't2',
        type: 'solana_transfer',
        asset: 'solana:USDC',
        from: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        to: _demoAddress,
        gas: 0,
        nonce: 0,
        amount: lw.Amount(BigInt.from(50000000), 6),
        fiatAmount: lw.Amount(BigInt.from(5000), 2),
        fiatCurrency: 'USD',
        created: ago(const Duration(days: 1, hours: 13, minutes: 12)),
      ),
      lw.Transaction(
        id: 't3',
        type: 'solana_transfer',
        asset: 'solana:$_chiefPussyMint',
        from: _demoAddress,
        to: 'A8z2pNqLcvR3yKdnFw5mEbzBpgX1tF6JvE9vKuRdpNqL',
        gas: 0,
        nonce: 0,
        amount: lw.Amount(BigInt.from(12000000000), 6),
        fiatAmount: lw.Amount(BigInt.from(449), 2),
        fiatCurrency: 'USD',
        created: ago(const Duration(days: 2, hours: 1)),
      ),
      lw.Transaction(
        id: 't4',
        type: 'solana_transfer',
        asset: 'solana:SOL',
        from: '5iTpwCMHzqU3JRwG8Fj5XaNqXdWkFQu3Ya5jrFUM4xVe',
        to: _demoAddress,
        gas: 0,
        nonce: 0,
        amount: lw.Amount(BigInt.from(800000000), 9),
        fiatAmount: lw.Amount(BigInt.from(19108), 2),
        fiatCurrency: 'USD',
        created: ago(const Duration(days: 3, hours: 4)),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Stub RpcService — overrides only the read methods invoked on initial render
// ---------------------------------------------------------------------------

class _StubRpcService extends RpcService {
  _StubRpcService() : super.real();

  @override
  Future<BigInt> getBalance(String address) async => _solBalance;

  @override
  Future<List<TokenAccount>> getTokenAccountsByOwner(
    String owner, {
    bool token2022 = false,
  }) async {
    if (token2022) return const [];
    return [
      TokenAccount(
        pubkey: 'TokAccChiefPussy11111111111111111111111111',
        mint: _chiefPussyMint,
        owner: _demoAddress,
        amount: _chiefPussyBalance,
        decimals: 6,
        rentLamports: BigInt.from(2039280),
      ),
      TokenAccount(
        pubkey: 'TokAccUSDC1111111111111111111111111111111',
        mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        owner: _demoAddress,
        amount: BigInt.zero,
        decimals: 6,
        rentLamports: BigInt.from(2039280),
      ),
      TokenAccount(
        pubkey: 'TokAccSpam1111111111111111111111111111111',
        mint: 'SpamMintToBurn1111111111111111111111111111',
        owner: _demoAddress,
        amount: BigInt.zero,
        decimals: 6,
        rentLamports: BigInt.from(2039280),
      ),
      TokenAccount(
        pubkey: 'TokAccJUP11111111111111111111111111111111',
        mint: 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',
        owner: _demoAddress,
        amount: BigInt.from(51230) * BigInt.from(10000),
        decimals: 6,
        rentLamports: BigInt.from(2039280),
      ),
    ];
  }

  @override
  Future<Map<String, TokenMetadata>> getAssetBatch(List<String> mints) async {
    return {
      _chiefPussyMint: TokenMetadata(
        mint: _chiefPussyMint,
        name: 'Tibane Thecat',
        symbol: r'$ChiefPussy',
        decimals: 6,
        pricePerToken: 0.0000374,
        supply: BigInt.from(1000000000) * BigInt.from(1000000),
      ),
      'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': TokenMetadata(
        mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        name: 'USD Coin',
        symbol: 'USDC',
        decimals: 6,
      ),
      'SpamMintToBurn1111111111111111111111111111': TokenMetadata(
        mint: 'SpamMintToBurn1111111111111111111111111111',
        name: 'Spam Airdrop',
        symbol: 'SPAM',
        decimals: 6,
      ),
      'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN': TokenMetadata(
        mint: 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',
        name: 'Jupiter',
        symbol: 'JUP',
        decimals: 6,
        pricePerToken: 0.556,
      ),
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getAssetsByOwner(
    String owner, {
    int page = 1,
    int limit = 1000,
  }) async {
    if (page > 1) return const [];
    // Mix of compressed + regular NFTs for the incinerator gallery.
    return [
      _heliusNft(
        'NFT01',
        'Solana Monkey #4823',
        collection: 'Solana Monkey Business',
        compressed: false,
      ),
      _heliusNft(
        'NFT02',
        'Mad Lad #2104',
        collection: 'Mad Lads',
        compressed: false,
      ),
      _heliusNft(
        'NFT03',
        'Tensorian #1042',
        collection: 'Tensorians',
        compressed: true,
      ),
      _heliusNft(
        'NFT04',
        'DeGod (burned)',
        collection: 'DeGods',
        compressed: false,
      ),
    ];
  }

  @override
  Future<TokenMetadata?> getAsset(String mint) async {
    if (mint == _chiefPussyMint) {
      return TokenMetadata(
        mint: _chiefPussyMint,
        name: 'Tibane Thecat',
        symbol: r'$ChiefPussy',
        decimals: 6,
        pricePerToken: 0.0000374,
        supply: BigInt.from(1000000000) * BigInt.from(1000000),
        burned: BigInt.from(8200000) * BigInt.from(1000000),
      );
    }
    return null;
  }

  @override
  Future<List<TokenHolder>> getTopHolders(String mint, {int limit = 10}) async {
    return [
      TokenHolder(
        address: _poolVault,
        amount: BigInt.from(128540) * BigInt.from(1000000),
        percentage: 12.85,
      ),
      TokenHolder(
        address: '2tFM8eJk9k1pqRfHm8m1Vd3hKLxPnEHbz9hDpoKw3pLp',
        amount: BigInt.zero,
        percentage: 8.42,
      ),
      TokenHolder(
        address: '4nQyMP8nN1Y3VqV8BbAm6PCa5sNmRNRnFkVKjE9QWbpL',
        amount: BigInt.zero,
        percentage: 6.01,
      ),
      TokenHolder(
        address: '7HxQ8wJYFC2tF7eYBKRNzJpRLgr5PoX1V3UQbHk2yVtP',
        amount: BigInt.zero,
        percentage: 4.27,
      ),
      TokenHolder(
        address: '5JbF4aTzQwPLxV9wRMzbKpEf2K1HXyFvL3aRuJK7tPxc',
        amount: BigInt.zero,
        percentage: 3.92,
      ),
      TokenHolder(
        address: 'GbE1n5DvkLJa4HxzmYrCpFwTQ8L2mnvN9R3kVsX7P5dx',
        amount: BigInt.zero,
        percentage: 2.84,
      ),
      TokenHolder(
        address: 'CtPwLrR3vEbBnXoQjF7Tf2jZLm5uS8KhV9PaGzWpKxNc',
        amount: BigInt.zero,
        percentage: 2.41,
      ),
      TokenHolder(
        address: 'AaPxR4WeBcF5LjMnQzKsX2VtN8YpDkR3HfTbJgVwUcLm',
        amount: BigInt.zero,
        percentage: 2.10,
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getSignaturesForAddress(
    String address, {
    int limit = 20,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return [
      {
        'signature':
            '5jKvT3yWxZcMpFqL8aRnQbE2sVfKgN1HpYxJ9rWdLm6vTcXkPnB7zE3qF5R8jVtA1S2dG4hY6uW9oP',
        'blockTime': now - 240,
      },
      {
        'signature':
            '2vMfPxL9bC7tWqRyJaE3pHkZ8nXoVdRgFbKjLm5sN1uW4yY6cP3qE2tDhV9fS8jRkXmA1BzG7vUoJ',
        'blockTime': now - 1140,
      },
      {
        'signature':
            '8fKbMzPxC4tWqJyLaE3pHnZ7nXoVdRgFbVjLm5sN1uW4yY6cP3qE2tDhV9fS8jRkXmA1BzG7vUoFa',
        'blockTime': now - 4500,
      },
      {
        'signature':
            '3pKjT9bWqMxLfZc4tWqRyJaE3pHkZ8nXoVdRgFbKjLm5sN1uW4yY6cP3qE2tDhV9fS8jRkXmA1BzG',
        'blockTime': now - 11400,
      },
      {
        'signature':
            'XbF2pKjT9MqLxZc4tWqRyJaE3pHkZ8nXoVdRgFbKjLm5sN1uW4yY6cP3qE2tDhV9fS8jRkXmA1BzG',
        'blockTime': now - 28800,
      },
    ];
  }

  @override
  Future<Uint8List?> getAccountInfo(String address) async => null;

  @override
  Future<({Uint8List? data, BigInt lamports, String? owner})?>
  getAccountInfoFull(String address) async {
    return (
      data: null,
      lamports: BigInt.from(2483100000),
      owner: 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
    );
  }

  @override
  Future<UserStake?> getUserStake(
    String poolAddress,
    String userAddress,
  ) async {
    return UserStake(
      owner: userAddress,
      pool: poolAddress,
      amount: BigInt.from(5000) * BigInt.from(1000000),
      // 5,000 $CP
      stakeTime: BigInt.from(
        DateTime.now()
                .subtract(const Duration(days: 14))
                .millisecondsSinceEpoch ~/
            1000,
      ),
      expStartFactor: BigInt.zero,
      rewardDebt: BigInt.zero,
      bump: 255,
      unstakeRequestAmount: BigInt.zero,
      unstakeRequestTime: BigInt.zero,
      lastStakeTime: BigInt.from(
        DateTime.now()
                .subtract(const Duration(days: 7))
                .millisecondsSinceEpoch ~/
            1000,
      ),
      baseTimeSnapshot: BigInt.zero,
      totalRewardsClaimed: BigInt.from(123000000),
      // 0.123 SOL claimed
      claimedRewardsWad: BigInt.zero,
    );
  }

  @override
  Future<StakingPool?> getStakingPool(String address) async => _mockTopPool();

  @override
  void dispose() {} // skip super.dispose() — _client wasn't really used
}

// ---------------------------------------------------------------------------
// Stub ChiefStakerApi
// ---------------------------------------------------------------------------

class _StubChiefStakerApi extends ChiefStakerApi {
  _StubChiefStakerApi() : super.real();

  @override
  Future<List<StakingPool>> listPools({int perPage = 100}) async {
    return [
      _mockTopPool(),
      _mockPool(
        name: 'Bonk',
        symbol: 'BONK',
        mint: 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263',
        members: 287,
        rewardSol: 12.84,
        staked: BigInt.from(95200000) * BigInt.from(100000),
        decimals: 5,
        price: 0.0000094,
        supply: BigInt.from(94800000000000) * BigInt.from(100000),
      ),
      _mockPool(
        name: 'Jito',
        symbol: 'JTO',
        mint: 'jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL',
        members: 154,
        rewardSol: 6.71,
        staked: BigInt.from(42100) * BigInt.from(1000000000),
        decimals: 9,
        price: 2.41,
        supply: BigInt.from(254000000) * BigInt.from(1000000000),
      ),
      _mockPool(
        name: 'Jupiter',
        symbol: 'JUP',
        mint: 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN',
        members: 121,
        rewardSol: 4.92,
        staked: BigInt.from(28500) * BigInt.from(1000000),
        decimals: 6,
        price: 0.556,
        supply: BigInt.from(10000000000) * BigInt.from(1000000),
      ),
      _mockPool(
        name: 'Pyth',
        symbol: 'PYTH',
        mint: 'HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3',
        members: 89,
        rewardSol: 3.18,
        staked: BigInt.from(124000) * BigInt.from(1000000),
        decimals: 6,
        price: 0.184,
        supply: BigInt.from(10000000000) * BigInt.from(1000000),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// StakingPool / NFT factories
// ---------------------------------------------------------------------------

StakingPool _mockTopPool() => _mockPool(
  name: 'Tibane Thecat',
  symbol: r'$ChiefPussy',
  mint: _chiefPussyMint,
  members: 412,
  rewardSol: 34.21,
  staked: BigInt.from(128540) * BigInt.from(1000000),
  decimals: 6,
  price: 0.0000374,
  supply: BigInt.from(1000000000) * BigInt.from(1000000),
  address: _poolAddress,
  authority: _poolAuthority,
  vault: _poolVault,
);

StakingPool _mockPool({
  required String name,
  required String symbol,
  required String mint,
  required int members,
  required double rewardSol,
  required BigInt staked,
  required int decimals,
  required double price,
  required BigInt supply,
  String? address,
  String? authority,
  String? vault,
}) {
  final base = BigInt.from(
    DateTime.now().subtract(const Duration(days: 94)).millisecondsSinceEpoch ~/
        1000,
  );
  return StakingPool(
    address: address ?? 'PooL${name}11111111111111111111111111111111',
    mint: mint,
    tokenVault: vault ?? 'VauLT${name}11111111111111111111111111111111',
    authority: authority ?? 'AuTH${name}11111111111111111111111111111111',
    totalStaked: staked,
    sumStakeExp: BigInt.zero,
    tauSeconds: BigInt.from(86400 * 7),
    // 7d tau
    baseTime: base,
    accRewardPerWeightedShare: BigInt.zero,
    lastUpdateTime: BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000),
    bump: 255,
    lastSyncedLamports: BigInt.from((rewardSol * 1e9).toInt()),
    minStakeAmount: BigInt.from(100) * BigInt.from(1000000),
    lockDurationSeconds: BigInt.from(86400),
    unstakeCooldownSeconds: BigInt.from(86400 * 3),
    initialBaseTime: base,
    tokenName: name,
    tokenSymbol: symbol,
    tokenDecimals: decimals,
    memberCount: members,
    rewardBalance: BigInt.from((rewardSol * 1e9).toInt()),
    tokenPrice: price,
    tokenSupply: supply,
  );
}

Map<String, dynamic> _heliusNft(
  String id,
  String name, {
  required String collection,
  required bool compressed,
}) {
  return {
    'id': id.padRight(44, '1'),
    'content': {
      'metadata': {'name': name, 'symbol': 'NFT'},
      'links': {'image': 'https://example.invalid/$id.png'},
    },
    'compression': compressed
        ? {'compressed': true, 'tree': 'tree$id', 'leaf_id': 1}
        : {'compressed': false},
    'grouping': [
      {'group_key': 'collection', 'group_value': collection},
    ],
  };
}
