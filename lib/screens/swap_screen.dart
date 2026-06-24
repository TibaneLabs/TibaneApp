import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:libwallet/libwallet.dart' show SwapTokenRef, SigningKey;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/solana_constants.dart';
import '../services/favorites_service.dart';
import '../services/jupiter_service.dart';
import '../services/rpc_service.dart';
import '../services/tx_confirmation.dart';
import '../services/uk_compliance_service.dart';
import '../services/wallet/libwallet_backend.dart' show TokenSearchResult;
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';
import '../widgets/token_icon.dart';
import '../widgets/token_search.dart';
import 'wallet/inapp_unlock_screen.dart';
import '../utils/amount.dart';
import '../utils/log.dart';

class SwapScreen extends StatefulWidget {
  /// Optional input mint to pre-select once holdings finish loading. Pass
  /// the wSOL mint (`So11…1112`) to default to SOL. When null, the user
  /// must pick from holdings.
  final String? initialInputMint;

  /// Optional output mint. Defaults to ChiefPussy when null (Tibane's
  /// default destination on the home screen Swap action).
  final String? initialOutputMint;

  /// Optional output-token metadata supplied by the caller so the picker
  /// can show the right symbol / name / image without making the user
  /// re-pick. Used by the staking detail screen which knows the pool's
  /// token already.
  final String? initialOutputSymbol;
  final String? initialOutputName;
  final String? initialOutputImageUrl;
  final int? initialOutputDecimals;

  const SwapScreen({
    super.key,
    this.initialInputMint,
    this.initialOutputMint,
    this.initialOutputSymbol,
    this.initialOutputName,
    this.initialOutputImageUrl,
    this.initialOutputDecimals,
  });

  @override
  State<SwapScreen> createState() => _SwapScreenState();
}

/// Clean up raw exceptions into user-friendly messages
String _friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('No address associated')) {
    return 'No internet connection';
  }
  if (s.contains('Connection refused') || s.contains('Connection reset')) {
    return 'Server unavailable, try again later';
  }
  if (s.contains('TimeoutException') || s.contains('timed out')) {
    return 'Request timed out, try again';
  }
  // Strip "Exception: " prefix
  return s.replaceFirst('Exception: ', '');
}

class _SwapScreenState extends State<SwapScreen> with TxConfirmationRefresh {
  final _jupiter = JupiterService();
  final _amountController = TextEditingController();
  WalletService? _wallet;

  // Holdings (input tokens)
  List<TokenHolding> _holdings = [];
  bool _loadingHoldings = false;

  // Selected input/output
  TokenHolding? _selectedInput;
  _SwapToken? _selectedOutput;

  // Quote — one of these is non-null when a quote is ready
  SwapQuote? _jupiterQuote; // MWA path
  lw.SwapQuote? _lwQuote; // in-app path
  bool _hasQuote = false;
  double? _quoteOutUi;
  bool _loadingQuote = false;
  String? _quoteError;
  Timer? _quoteDebounce;

  // Swap execution
  bool _swapping = false;
  String? _error;

  // Output token metadata cache (for decimals)
  int _outputDecimals = 9;
  String? _outputImageUrl;

  bool _walletWasConnected = false;

  // Swap availability on the active network (per libwallet's policy).
  lw.SwapAvailability? _swapAvailability;
  bool _checkingAvailability = false;
  bool _switchingNetwork = false;
  String? _lastCheckedNetworkId;

  bool _quoteDetailsExpanded = false;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountChanged);

    // Default output: ChiefPussy unless caller overrode it. Callers that
    // know the token's metadata (staking detail, token-row tap, etc.)
    // should pass it in so the picker displays the right name/icon
    // immediately. The libwallet quote will replace decimals with the
    // authoritative value once it lands.
    //
    // When the caller passes an output mint without its symbol / name
    // (e.g. the wallet dashboard's tap-to-swap-to-SOL shortcut), fall
    // back to the curated commonTokens entry for that mint so the TO
    // field doesn't render with the icon-only / empty-text glitch.
    // The flip button copies these fields into the new INPUT row, so a
    // blank symbol here would also leak into FROM after a flip.
    final initOutMint = widget.initialOutputMint ?? chiefPussyMint;
    final fallback = commonTokens.firstWhere(
      (t) => t.mint == initOutMint,
      orElse: () => const CommonToken(mint: '', symbol: '', name: ''),
    );
    _selectedOutput = _SwapToken(
      mint: initOutMint,
      symbol: widget.initialOutputSymbol ?? fallback.symbol,
      name: widget.initialOutputName ?? fallback.name,
      imageUrl: widget.initialOutputImageUrl ?? fallback.imageUrl,
    );
    _outputDecimals =
        widget.initialOutputDecimals ?? (initOutMint == wsolMint ? 9 : 6);
    _outputImageUrl = widget.initialOutputImageUrl ?? fallback.imageUrl;

    final wallet = context.read<WalletService>();
    _wallet = wallet;
    wallet.addListener(_onWalletChanged);
    // Reload holdings whenever the chain state changes — covers swaps
    // from other surfaces, sends, and libwallet's 60s background poller.
    // Without this the From-section balance and token picker values keep
    // showing the pre-swap numbers until the user navigates away and back.
    wallet.libwallet.balanceTick.addListener(_onBalanceTick);
    wallet.swapCommittedTick.addListener(_onBalanceTick);
    if (wallet.isConnected) {
      _walletWasConnected = true;
      _loadHoldings();
    }
    _checkAvailability();
  }

  void _onBalanceTick() {
    if (!mounted) return;
    final wallet = _wallet;
    if (wallet == null || !wallet.isConnected) return;
    _loadHoldings();
  }

  void _onWalletChanged() {
    final wallet = context.read<WalletService>();
    // Re-check swap availability whenever the active network changes.
    final netId = wallet.libwallet.currentNetwork?.id;
    if (netId != _lastCheckedNetworkId) {
      _checkAvailability();
    }
    if (wallet.isConnected && !_walletWasConnected) {
      _walletWasConnected = true;
      _loadHoldings();
    } else if (!wallet.isConnected && _walletWasConnected) {
      _walletWasConnected = false;
      setState(() {
        _holdings = [];
        _selectedInput = null;
        _jupiterQuote = null;
        _lwQuote = null;
        _hasQuote = false;
        _quoteOutUi = null;
        _quoteError = null;
        _error = null;
        _amountController.clear();
      });
    }
  }

  @override
  void dispose() {
    _wallet?.removeListener(_onWalletChanged);
    _wallet?.libwallet.balanceTick.removeListener(_onBalanceTick);
    _wallet?.swapCommittedTick.removeListener(_onBalanceTick);
    _amountController.dispose();
    _quoteDebounce?.cancel();
    _jupiter.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    _quoteDebounce?.cancel();
    setState(() {
      _jupiterQuote = null;
      _lwQuote = null;
      _hasQuote = false;
      _quoteOutUi = null;
      _quoteError = null;
    });
    if (_amountController.text.isNotEmpty &&
        _selectedInput != null &&
        _selectedOutput != null) {
      _quoteDebounce = Timer(const Duration(milliseconds: 500), _fetchQuote);
    }
  }

  /// Ask libwallet whether swap is currently routable on the active
  /// network. The result drives a banner that replaces the swap form
  /// when the answer is no.
  Future<void> _checkAvailability() async {
    if (_checkingAvailability) return;
    setState(() => _checkingAvailability = true);
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      await wallet.libwallet.refreshCurrentNetwork();
      final avail = await client.swap.availability();
      if (!mounted) return;
      setState(() {
        _swapAvailability = avail;
        _lastCheckedNetworkId = wallet.libwallet.currentNetwork?.id;
        _checkingAvailability = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingAvailability = false);
      debugPrint('swap.availability failed: $e');
    }
  }

  /// One-tap recovery for the "swap unavailable" banner: ask libwallet
  /// to flip the current network back to Solana mainnet. Resets the
  /// swap form so we re-fetch holdings on the new chain.
  Future<void> _switchToSolana() async {
    if (_switchingNetwork) return;
    setState(() => _switchingNetwork = true);
    final wallet = context.read<WalletService>();
    try {
      final client = await wallet.libwallet.ensureClient();
      final nets = await client.networks.list();
      lw.Network? pick;
      for (final n in nets) {
        if (n.type == lw.NetworkType.solana && !n.testNet) {
          pick = n;
          break;
        }
      }
      if (pick == null) {
        if (!mounted) return;
        setState(() => _switchingNetwork = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No Solana mainnet network configured')),
        );
        return;
      }
      final ok = await wallet.libwallet.setCurrentNetwork(pick.id);
      if (!mounted) return;
      setState(() {
        _switchingNetwork = false;
        _holdings = const [];
        _selectedInput = null;
        _amountController.clear();
        _hasQuote = false;
        _lwQuote = null;
        _jupiterQuote = null;
        _quoteOutUi = null;
        _quoteError = null;
      });
      if (ok) {
        await _checkAvailability();
        if (mounted && wallet.isConnected) await _loadHoldings();
      }
    } catch (e) {
      logError('[swap._switchToSolana] error: $e');
      if (!mounted) return;
      setState(() => _switchingNetwork = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Switch failed: $e')));
    }
  }

  Widget _buildUnavailableBanner() {
    final a = _swapAvailability!;
    final wallet = context.read<WalletService>();
    final netName = wallet.libwallet.currentNetwork?.name ?? 'this network';
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: TibaneColors.warning,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Swap unavailable on $netName',
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _availabilityMessage(a),
            style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _switchingNetwork ? null : _switchToSolana,
            style: FilledButton.styleFrom(
              backgroundColor: TibaneColors.orange,
              foregroundColor: TibaneColors.black,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.flash_on, size: 18),
            label: Text(
              _switchingNetwork ? 'Switching…' : 'Switch to Solana mainnet',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  String _availabilityMessage(lw.SwapAvailability a) {
    switch (a.reason) {
      case 'unsupported_chain':
        return 'Swap isn\'t supported on the current network. Switch to '
            'Solana mainnet or any EVM chain covered by 1inch.';
      case 'missing_api_key':
        return 'Swap is supported here but the 1inch API key isn\'t '
            'configured in this build. Switch to Solana mainnet to swap '
            'now.';
      default:
        return a.reason.isEmpty
            ? 'Swap is unavailable on the current network.'
            : 'Swap unavailable: ${a.reason}';
    }
  }

  Future<void> _loadHoldings() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() {
      _loadingHoldings = true;
      _error = null;
    });

    try {
      final holdings = await _jupiter.fetchHoldings(
        wallet.publicKey!,
        excludeMint: _selectedOutput?.mint,
      );
      if (!mounted) return;
      setState(() {
        _holdings = holdings;
        _loadingHoldings = false;
        // Update or clear selected input with fresh data
        if (_selectedInput != null) {
          final updated = holdings.cast<TokenHolding?>().firstWhere(
            (h) => h!.mint == _selectedInput!.mint,
            orElse: () => null,
          );
          if (updated != null) {
            _selectedInput = updated;
          } else {
            _selectedInput = null;
            _amountController.clear();
          }
        } else if (widget.initialInputMint != null) {
          // Caller asked us to pre-select a specific input — find the
          // matching holding now that the list is loaded. Falls through
          // silently if the user doesn't hold that asset.
          final wanted = widget.initialInputMint!;
          final match = holdings.cast<TokenHolding?>().firstWhere(
            (h) => h!.mint == wanted,
            orElse: () => null,
          );
          if (match != null) _selectedInput = match;
        }
      });
    } catch (e) {
      logError('[swap._loadHoldings] error: $e');
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _loadingHoldings = false;
      });
    }
  }

  Future<void> _fetchQuote() async {
    if (_selectedInput == null || _selectedOutput == null) return;
    // Accept both period and comma as the decimal separator — the iOS
    // numeric keyboard adapts to the device locale, so European users
    // get a comma key and Dart's parser would otherwise reject it.
    final amountStr = normalizeDecimal(_amountController.text);
    if (amountStr.isEmpty) return;

    final amountFloat = double.tryParse(amountStr);
    if (amountFloat == null || amountFloat <= 0) return;
    if (amountFloat > _selectedInput!.uiBalance) {
      setState(() => _quoteError = 'Amount exceeds balance');
      return;
    }

    final rawAmount = BigInt.from(
      amountFloat * BigInt.from(10).pow(_selectedInput!.decimals).toDouble(),
    );
    if (rawAmount <= BigInt.zero) return;

    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() {
      _loadingQuote = true;
      _quoteError = null;
    });

    try {
      if (wallet.kind == WalletKind.inapp && wallet.libwallet.isUnlocked) {
        await _fetchQuoteLibwallet(wallet, rawAmount);
      } else {
        await _fetchQuoteJupiter(wallet, rawAmount);
      }
    } catch (e) {
      logError('[swap._fetchQuote] error: $e');
      if (!mounted) return;
      setState(() {
        _quoteError = _friendlyError(e);
        _loadingQuote = false;
      });
    }
  }

  Future<void> _fetchQuoteJupiter(
    WalletService wallet,
    BigInt rawAmount,
  ) async {
    final quote = await _jupiter.fetchQuote(
      inputMint: _selectedInput!.mint,
      outputMint: _selectedOutput!.mint,
      amount: rawAmount,
      taker: wallet.publicKey!,
      outputDecimals: _outputDecimals,
    );
    if (!mounted) return;
    setState(() {
      _jupiterQuote = quote;
      _lwQuote = null;
      _hasQuote = true;
      _quoteOutUi = quote.outAmountUi;
      _loadingQuote = false;
    });
  }

  Future<void> _fetchQuoteLibwallet(
    WalletService wallet,
    BigInt rawAmount,
  ) async {
    final inputMint = _selectedInput!.mint;
    final outputMint = _selectedOutput!.mint;
    final client = await wallet.libwallet.ensureClient();
    // libwallet 0.4.31 dropped the silent Jupiter→dFlow fallback from
    // swap.quote(). Use swap.quotes() so we get an attempt from every
    // provider and pick the one with the highest output. If none
    // succeed we surface the first error's message.
    final attempts = await client.swap.quotes(
      tokenIn: SwapTokenRef(
        address: inputMint == wsolMint ? 'NATIVE' : inputMint,
        decimals: _selectedInput!.decimals,
      ),
      tokenOut: SwapTokenRef(
        address: outputMint == wsolMint ? 'NATIVE' : outputMint,
        decimals: _outputDecimals,
      ),
      amountIn: rawAmount.toString(),
    );
    if (!mounted) return;
    lw.QuoteAttempt? best;
    for (final a in attempts) {
      if (!a.isOk) continue;
      if (best == null ||
          a.quote!.amountOut.toDouble() > best.quote!.amountOut.toDouble()) {
        best = a;
      }
    }
    if (best == null) {
      // Every provider failed. Bubble up the most useful message.
      final firstErr = attempts.firstWhere(
        (a) => a.error != null,
        orElse: () => attempts.isNotEmpty
            ? attempts.first
            : const lw.QuoteAttempt(provider: '', providerLabel: ''),
      );
      final code = firstErr.error?.code ?? 'no_route';
      final msg =
          firstErr.error?.message ?? 'No provider could quote this pair';
      throw Exception('$msg ($code)');
    }
    final quote = best.quote!;
    setState(() {
      _lwQuote = quote;
      _jupiterQuote = null;
      _hasQuote = true;
      _quoteOutUi = quote.amountOut.toDouble();
      _loadingQuote = false;
    });
  }

  Future<void> _setPercent(int percent) async {
    if (_selectedInput == null) return;
    // For 100% with both tokens picked, ask libwallet for the true
    // maxSpendable — it reserves gas and accounts for ATA-creation rent
    // on the output mint. Falls back to raw balance × percent on hard
    // errors (network etc.) so the Max button never appears broken.
    double amount;
    if (percent == 100 && _selectedOutput != null) {
      try {
        final wallet = context.read<WalletService>();
        final client = await wallet.libwallet.ensureClient();
        final quote = await client.swap.maxSpendable(
          tokenIn: SwapTokenRef(
            address: _selectedInput!.mint == wsolMint
                ? 'NATIVE'
                : _selectedInput!.mint,
            decimals: _selectedInput!.decimals,
            symbol: _selectedInput!.symbol,
          ),
          tokenOut: SwapTokenRef(
            address: _selectedOutput!.mint == wsolMint
                ? 'NATIVE'
                : _selectedOutput!.mint,
            // Output decimals aren't tracked on _SwapToken; the swap RPC
            // only uses tokenOut.decimals for output-amount formatting,
            // which we don't read out of the maxSpendable response — pass
            // a reasonable default. SOL is 9; most SPL tokens we surface
            // (USDC, USDT, pump.fun) are 6.
            decimals: _selectedOutput!.mint == wsolMint ? 9 : 6,
            symbol: _selectedOutput!.symbol,
          ),
          from: wallet.publicKey,
        );
        if (!mounted) return;
        // libwallet 0.4.35: soft failures (balance_too_small / no_route)
        // no longer throw — maxSpendable returns a non-executable quote
        // with a human-readable statusMessage. Surface it instead of
        // silently filling the field with an amount that won't actually
        // swap.
        if (!quote.isExecutable) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                quote.statusMessage.isNotEmpty
                    ? quote.statusMessage
                    : 'Max amount unavailable for this pair',
              ),
            ),
          );
          return;
        }
        final raw = quote.amountIn.value;
        final divisor = BigInt.from(10).pow(_selectedInput!.decimals);
        amount = raw / divisor;
      } catch (e) {
        debugPrint('swap.maxSpendable fallback: $e');
        amount = _selectedInput!.uiBalance;
      }
    } else {
      amount = _selectedInput!.uiBalance * percent / 100;
    }
    final decimals = _selectedInput!.decimals.clamp(0, 6);
    var text = amount.toStringAsFixed(decimals);
    if (text.contains('.')) {
      text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    if (!mounted) return;
    _amountController.text = text;
  }

  Future<void> _executeSwap() async {
    if (!_hasQuote || _swapping) return;
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;
    if (!mounted) return;

    // Snapshot the trade before clearing state on success so the result
    // sheet has names + amounts to display.
    final inputSymbol = _selectedInput?.symbol ?? '';
    final outputSymbol = _selectedOutput?.symbol ?? '';
    final inputAmount = parseAmount(_amountController.text) ?? 0;
    final outputAmount = _quoteOutUi ?? 0;
    final outputMint = _selectedOutput?.mint;

    setState(() {
      _swapping = true;
      _error = null;
    });

    try {
      String signature;
      if (_lwQuote != null) {
        signature = await _executeSwapLibwallet(wallet);
      } else {
        signature = await _executeSwapJupiter(wallet);
      }

      if (!mounted) return;
      setState(() {
        _jupiterQuote = null;
        _lwQuote = null;
        _hasQuote = false;
        _quoteOutUi = null;
        _amountController.clear();
      });
      // libwallet 0.4.27 handles both balance-refresh notification and
      // auto-registration of unknown swap outputs server-side, but kick
      // the wallet service explicitly so any dashboard view that's
      // mounted in another tab reloads now instead of waiting for the
      // txHistory stream to fire.
      wallet.notifyTxCommitted();
      // Re-pull our own holdings now + on the confirmation-delay schedule (the
      // swap screen stays mounted). notifyTxCommitted covers balances + the
      // dashboard with its own service-level delayed re-polls.
      refreshAfterTx(_loadHoldings);
      // libwallet's auto-discovery doesn't always pick up a brand-new
      // mint before the next Asset:list call. Register the swap output
      // explicitly with the metadata we already have so the token row
      // appears on the dashboard the moment the balance lands. We have
      // to nudge again once it's in so the dashboard reloads after the
      // first registration completes.
      if (outputMint != null && outputMint != wsolMint) {
        unawaited(
          wallet.libwallet
              .ensureTokenTracked(
                mint: outputMint,
                name: _selectedOutput?.name,
                symbol: outputSymbol,
                decimals: _outputDecimals,
              )
              .then((added) {
                if (added && mounted) wallet.notifyTxCommitted();
              }),
        );
      }
      // Show the success sheet. Don't await — let it sit while we kick
      // off a few delayed balance refreshes for confirmation.
      unawaited(
        _showSwapResultSheet(
          signature: signature,
          inputSymbol: inputSymbol,
          outputSymbol: outputSymbol,
          inputAmount: inputAmount,
          outputAmount: outputAmount,
          outputMint: outputMint,
        ),
      );
    } catch (e) {
      logError('[swap._executeSwap] error: $e');
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _swapping = false);
      }
    }
  }

  Future<void> _showSwapResultSheet({
    required String signature,
    required String inputSymbol,
    required String outputSymbol,
    required double inputAmount,
    required double outputAmount,
    required String? outputMint,
  }) async {
    final wallet = context.read<WalletService>();
    final net = wallet.libwallet.currentNetwork;
    // libwallet 0.4.29: Network.transactionUrl handles per-chain URL
    // composition (`?cluster=` for non-mainnet Solana, /tx/ vs /address/
    // paths, "" when no explorer is resolvable). Falls back to Solscan
    // when the active network has no resolved explorer.
    String? explorerUrl;
    if (net != null) {
      final composed = net.transactionUrl(signature);
      if (composed.isNotEmpty) {
        explorerUrl = composed;
      } else if (net.type == lw.NetworkType.solana) {
        explorerUrl = 'https://solscan.io/tx/$signature';
      }
    } else {
      explorerUrl = 'https://solscan.io/tx/$signature';
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TibaneColors.card,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _SwapResultSheet(
        signature: signature,
        inputSymbol: inputSymbol,
        outputSymbol: outputSymbol,
        inputAmount: inputAmount,
        outputAmount: outputAmount,
        explorerUrl: explorerUrl,
        networkName: net?.name ?? '',
      ),
    );
  }

  Future<String> _executeSwapJupiter(WalletService wallet) async {
    final q = _jupiterQuote!;
    final txBytes = base64Decode(q.transaction);
    final signedBytes = await wallet.signTransaction(
      Uint8List.fromList(txBytes),
    );
    if (signedBytes == null)
      throw Exception('Transaction signing was rejected');
    final signedBase64 = base64Encode(signedBytes);
    return _jupiter.executeSwap(
      signedTransactionBase64: signedBase64,
      requestId: q.requestId,
    );
  }

  Future<String> _executeSwapLibwallet(WalletService wallet) async {
    final q = _lwQuote!;
    final client = await wallet.libwallet.ensureClient();
    final keys = wallet.libwallet.currentSigningKeys
        .map(
          (k) => SigningKey(
            id: k['Id'] as String,
            key: k['Key'] as String,
            type: k['Type'] as String?,
          ),
        )
        .toList();
    final result = await client.swap.execute(quoteId: q.quoteId, keys: keys);
    return result.hash;
  }

  void _selectInput(TokenHolding holding) {
    setState(() {
      _selectedInput = holding;
      _jupiterQuote = null;
      _lwQuote = null;
      _hasQuote = false;
      _quoteOutUi = null;
      _quoteError = null;
      _amountController.clear();
    });
  }

  void _flipTokens() {
    if (_selectedInput == null && _selectedOutput == null) return;

    final oldInput = _selectedInput;
    final oldOutput = _selectedOutput;

    // Find the output token in holdings to use as new input
    TokenHolding? newInput;
    if (oldOutput != null) {
      newInput = _holdings.firstWhere(
        (h) => h.mint == oldOutput.mint,
        orElse: () => TokenHolding(
          mint: oldOutput.mint,
          symbol: oldOutput.symbol,
          name: oldOutput.name,
          imageUrl: oldOutput.imageUrl,
          balance: BigInt.zero,
          decimals: _outputDecimals,
          uiBalance: 0,
        ),
      );
    }

    _SwapToken? newOutput;
    if (oldInput != null) {
      newOutput = _SwapToken(
        mint: oldInput.mint,
        symbol: oldInput.symbol,
        name: oldInput.name,
        imageUrl: oldInput.imageUrl,
      );
    }

    setState(() {
      _selectedInput = newInput;
      _selectedOutput = newOutput;
      if (newOutput != null) {
        _outputDecimals = oldInput?.decimals ?? 9;
        _outputImageUrl = oldInput?.imageUrl;
      }
      if (newInput != null) {
        _outputImageUrl = oldOutput?.imageUrl;
      }
      _jupiterQuote = null;
      _lwQuote = null;
      _hasQuote = false;
      _quoteOutUi = null;
      _quoteError = null;
      _amountController.clear();
    });

    // Reload holdings excluding new output
    _loadHoldings();
  }

  void _showOutputPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => _OutputTokenPicker(
        onSelect: (mint, symbol, name, imageUrl, decimals) {
          Navigator.pop(context);
          setState(() {
            _selectedOutput = _SwapToken(
              mint: mint,
              symbol: symbol,
              name: name,
              imageUrl: imageUrl,
            );
            _outputDecimals = decimals;
            _outputImageUrl = imageUrl;
            _jupiterQuote = null;
            _lwQuote = null;
            _hasQuote = false;
            _quoteOutUi = null;
            _quoteError = null;
          });
          // Reload holdings excluding new output
          _loadHoldings();
          // Re-fetch quote if we have input and amount
          if (_selectedInput != null && _amountController.text.isNotEmpty) {
            _quoteDebounce?.cancel();
            _quoteDebounce = Timer(
              const Duration(milliseconds: 300),
              _fetchQuote,
            );
          }
        },
      ),
    );
  }

  void _showInputPicker() {
    if (_holdings.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => _InputTokenPicker(
        holdings: _holdings,
        onSelect: (holding) {
          Navigator.pop(context);
          _selectInput(holding);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    if (context.watch<UkComplianceService>().isUk) {
      return const _SwapUnavailableInRegion();
    }

    return GestureDetector(
      // Tap anywhere outside the amount field to dismiss the iOS
      // numeric keyboard (which has no Done key by default).
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.translucent,
      child: RefreshIndicator(
        onRefresh: _loadHoldings,
        color: TibaneColors.orange,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          // Scrolling the list also dismisses the keyboard.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (!wallet.isConnected) ...[
              TibaneCard(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 48,
                          color: TibaneColors.textDim,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Connect wallet to swap',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else if (_swapAvailability != null &&
                !_swapAvailability!.available) ...[
              _buildUnavailableBanner(),
            ] else ...[
              // From section
              _buildFromSection(),
              const SizedBox(height: 8),

              // Flip button
              Center(
                child: IconButton(
                  onPressed: _flipTokens,
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: TibaneColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: TibaneColors.border),
                    ),
                    child: const Icon(
                      Icons.swap_vert,
                      color: TibaneColors.orange,
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // To section
              _buildToSection(),
              const SizedBox(height: 16),

              // Quote details
              if (_loadingQuote)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: TibaneColors.orange,
                      ),
                    ),
                  ),
                ),

              if (_quoteError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TibaneCard(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          color: TibaneColors.warning,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _quoteError!,
                            style: TextStyle(
                              color: TibaneColors.warning,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_hasQuote) _buildQuoteDetails(),

              // Error
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TibaneCard(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: TibaneColors.error,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: TibaneColors.error,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Swap button
              GradientButton(
                label: _swapping ? 'Swapping...' : 'Swap',
                icon: Icons.swap_horiz,
                expanded: true,
                loading: _swapping,
                onPressed: _hasQuote && !_swapping ? _executeSwap : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFromSection() {
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'From',
                style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
              ),
              const Spacer(),
              if (_selectedInput != null)
                Text(
                  'Balance: ${_formatBalance(_selectedInput!.uiBalance)}',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Token selector
              Expanded(
                child: InkWell(
                  onTap: _loadingHoldings ? null : _showInputPicker,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: TibaneColors.darker,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: TibaneColors.border),
                    ),
                    child: Row(
                      children: [
                        if (_selectedInput != null) ...[
                          TokenIcon(
                            imageUrl: _selectedInput!.imageUrl,
                            mint: _selectedInput!.mint,
                            symbol: _selectedInput!.symbol,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _selectedInput!.symbol,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ] else ...[
                          if (_loadingHoldings)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: TibaneColors.orange,
                              ),
                            )
                          else
                            const Icon(
                              Icons.token,
                              color: TibaneColors.textDim,
                              size: 20,
                            ),
                          const SizedBox(width: 8),
                          Text(
                            _loadingHoldings ? 'Loading...' : 'Select token',
                            style: TextStyle(color: TibaneColors.textMuted),
                          ),
                        ],
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.keyboard_arrow_down,
                          size: 18,
                          color: TibaneColors.textDim,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Amount input
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            style: monoStyle(fontSize: 20),
            decoration: InputDecoration(
              hintText: '0.00',
              hintStyle: monoStyle(fontSize: 20, color: TibaneColors.textDim),
              suffixText:
                  _selectedInput != null && _selectedInput!.priceUsd != null
                  ? '\$${(_formatUsd(parseAmount(_amountController.text) ?? 0, _selectedInput!.priceUsd!))}'
                  : null,
              suffixStyle: monoStyle(
                fontSize: 12,
                color: TibaneColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Percent buttons
          Row(
            children: [
              for (final pct in [25, 50, 75, 100])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: pct == 100 ? 0 : 6),
                    child: _PercentButton(
                      label: pct == 100 ? 'Max' : '$pct%',
                      onTap: _selectedInput != null
                          ? () => _setPercent(pct)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToSection() {
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'To',
            style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _showOutputPicker,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: TibaneColors.border),
              ),
              child: Row(
                children: [
                  if (_selectedOutput != null) ...[
                    TokenIcon(
                      imageUrl: _outputImageUrl ?? _selectedOutput!.imageUrl,
                      mint: _selectedOutput!.mint,
                      symbol: _selectedOutput!.symbol,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedOutput!.symbol,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else ...[
                    const Icon(
                      Icons.token,
                      color: TibaneColors.textDim,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Select token',
                      style: TextStyle(color: TibaneColors.textMuted),
                    ),
                  ],
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    color: TibaneColors.textDim,
                  ),
                ],
              ),
            ),
          ),
          if (_hasQuote && _quoteOutUi != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _formatOutputAmount(_quoteOutUi!),
                style: monoStyle(fontSize: 20, color: TibaneColors.cyan),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuoteDetails() {
    if (_lwQuote != null) return _buildLwQuoteDetails(_lwQuote!);
    if (_jupiterQuote != null) return _buildJupiterQuoteDetails(_jupiterQuote!);
    return const SizedBox.shrink();
  }

  Widget _buildJupiterQuoteDetails(SwapQuote q) {
    final summary = StringBuffer();
    if (q.outUsdValue != null) {
      summary.write('\$${q.outUsdValue!.toStringAsFixed(2)}');
    }
    summary.write('  ·  ${q.priceImpactPct}% impact');
    summary.write('  ·  0.5% fee');
    return _expandableCard(
      summary: summary.toString(),
      children: [
        if (q.inUsdValue != null)
          _quoteRow('You pay', '\$${q.inUsdValue!.toStringAsFixed(2)}'),
        if (q.outUsdValue != null)
          _quoteRow('You receive', '\$${q.outUsdValue!.toStringAsFixed(2)}'),
        _quoteRow('Price impact', '${q.priceImpactPct}%'),
        if (q.gasless)
          _quoteRow('Gas', 'Gasless', valueColor: TibaneColors.cyan),
        _quoteRow('Fee', '0.5%'),
      ],
    );
  }

  Widget _buildLwQuoteDetails(lw.SwapQuote q) {
    final provider = q.providerLabel.isNotEmpty ? q.providerLabel : q.provider;
    final summary = StringBuffer();
    summary.write(
      '${_formatOutputAmount(q.amountOut.toDouble())} ${q.tokenOut.symbol}',
    );
    if (q.priceImpact > 0) {
      summary.write('  ·  ${(q.priceImpact * 100).toStringAsFixed(2)}% impact');
    }
    summary.write('  ·  via $provider');
    return _expandableCard(
      summary: summary.toString(),
      children: [
        _quoteRow('Provider', provider),
        _quoteRow(
          'You receive',
          '${_formatOutputAmount(q.amountOut.toDouble())} ${q.tokenOut.symbol}',
        ),
        _quoteRow(
          'Min receive',
          _formatOutputAmount(q.minAmountOut.toDouble()),
        ),
        if (q.priceImpact > 0)
          _quoteRow(
            'Price impact',
            '${(q.priceImpact * 100).toStringAsFixed(2)}%',
          ),
        if (q.networkFee != null)
          _quoteRow(
            'Network fee',
            '${q.networkFee!.toDouble().toStringAsFixed(6)} SOL',
          ),
        _quoteRow('Fee', '${(q.feeBps / 100).toStringAsFixed(1)}%'),
        if (q.route.isNotEmpty)
          _quoteRow('Route', q.route.map((h) => h.venue).join(' → ')),
      ],
    );
  }

  /// Collapsible quote-details card. Default state is a one-line summary
  /// so the swap form fits on shorter screens; tapping the row reveals
  /// the full breakdown.
  Widget _expandableCard({
    required String summary,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TibaneCard(
        padding: EdgeInsets.zero,
        onTap: () =>
            setState(() => _quoteDetailsExpanded = !_quoteDetailsExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      summary,
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ),
                  Icon(
                    _quoteDetailsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: TibaneColors.textDim,
                    size: 18,
                  ),
                ],
              ),
              if (_quoteDetailsExpanded) ...[
                const SizedBox(height: 6),
                ...children,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _quoteRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
          ),
          Text(
            value,
            style: monoStyle(
              fontSize: 11,
              color: valueColor ?? TibaneColors.text,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBalance(double balance) {
    if (balance >= 1e9) return '${(balance / 1e9).toStringAsFixed(2)}B';
    if (balance >= 1e6) return '${(balance / 1e6).toStringAsFixed(2)}M';
    if (balance >= 1e3) return '${(balance / 1e3).toStringAsFixed(2)}K';
    if (balance >= 1) return balance.toStringAsFixed(4);
    return balance.toStringAsFixed(6);
  }

  String _formatOutputAmount(double amount) {
    if (amount >= 1e9) return '${(amount / 1e9).toStringAsFixed(4)}B';
    if (amount >= 1e6) return '${(amount / 1e6).toStringAsFixed(4)}M';
    if (amount >= 1e3) return '${(amount / 1e3).toStringAsFixed(4)}K';
    if (amount >= 1) return amount.toStringAsFixed(6);
    return amount.toStringAsFixed(8);
  }

  String _formatUsd(double amount, double price) {
    final usd = amount * price;
    return usd.toStringAsFixed(2);
  }
}

// Simple model for selected output token
class _SwapToken {
  final String mint;
  final String symbol;
  final String name;
  final String? imageUrl;

  _SwapToken({
    required this.mint,
    required this.symbol,
    required this.name,
    this.imageUrl,
  });
}

// Percent button
class _PercentButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _PercentButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: TibaneColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: TibaneColors.border),
        ),
        child: Center(
          child: Text(
            label,
            style: monoStyle(
              fontSize: 11,
              color: onTap != null ? TibaneColors.orange : TibaneColors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

// Input token picker bottom sheet
class _InputTokenPicker extends StatelessWidget {
  final List<TokenHolding> holdings;
  final void Function(TokenHolding) onSelect;

  const _InputTokenPicker({required this.holdings, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  'Select token to swap',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: holdings.length,
              itemBuilder: (context, index) {
                final h = holdings[index];
                return ListTile(
                  leading: TokenIcon(
                    imageUrl: h.imageUrl,
                    mint: h.mint,
                    symbol: h.symbol,
                    size: 36,
                  ),
                  title: Text(
                    h.symbol,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    h.name,
                    style: TextStyle(
                      color: TibaneColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatHoldingBalance(h.uiBalance),
                        style: monoStyle(fontSize: 12),
                      ),
                      if (h.valueUsd != null)
                        Text(
                          '\$${h.valueUsd!.toStringAsFixed(2)}',
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                  onTap: () => onSelect(h),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatHoldingBalance(double balance) {
    if (balance >= 1e6) return '${(balance / 1e6).toStringAsFixed(2)}M';
    if (balance >= 1e3) return '${(balance / 1e3).toStringAsFixed(2)}K';
    if (balance >= 1) return balance.toStringAsFixed(4);
    return balance.toStringAsFixed(6);
  }
}

// Output token picker bottom sheet
class _OutputTokenPicker extends StatefulWidget {
  final void Function(
    String mint,
    String symbol,
    String name,
    String? imageUrl,
    int decimals,
  )
  onSelect;

  const _OutputTokenPicker({required this.onSelect});

  @override
  State<_OutputTokenPicker> createState() => _OutputTokenPickerState();
}

class _OutputTokenPickerState extends State<_OutputTokenPicker> {
  /// Called when the user pastes a mint and submits — fetches the
  /// on-chain metadata so the swap selector gets the right decimals /
  /// symbol / logo. Curated-list taps go through [_selectResult] and
  /// skip this since they already carry the metadata.
  ///
  /// [TokenSearch] awaits the returned future and drives its suffix
  /// spinner for the duration, so no local loading flag is needed.
  Future<void> _selectByMint(String mint) async {
    final rpc = RpcService();
    try {
      final meta = await rpc.getAsset(mint);
      if (!mounted) return;
      if (meta == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Token not found')));
        return;
      }
      widget.onSelect(
        mint,
        meta.symbol ?? shortenAddress(mint),
        meta.name ?? mint,
        meta.imageUrl,
        meta.decimals,
      );
    } catch (e) {
      logError('[swap._selectByMint] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    } finally {
      rpc.dispose();
    }
  }

  void _selectResult(TokenSearchResult r) {
    // Curated list carries decimals; fall back to 6 (most SPL tokens)
    // when the entry is missing it for whatever reason.
    widget.onSelect(
      r.mint,
      r.symbol ?? shortenAddress(r.mint),
      r.name ?? r.mint,
      r.imageUrl,
      r.decimals ?? 6,
    );
  }

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesService>().favorites;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  'Select output token',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: TokenSearch(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollController: scrollController,
              onResultSelected: _selectResult,
              onMintSubmitted: _selectByMint,
              emptyBody: ListView(
                controller: scrollController,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      'POPULAR',
                      style: monoStyle(
                        fontSize: 10,
                        color: TibaneColors.textDim,
                      ),
                    ),
                  ),
                  for (final token in commonTokens)
                    ListTile(
                      leading: TokenIcon(
                        imageUrl: token.imageUrl,
                        mint: token.mint,
                        symbol: token.symbol,
                        size: 36,
                      ),
                      title: Text(
                        token.symbol,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        token.name,
                        style: TextStyle(
                          color: TibaneColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () {
                        // SOL=9, USDC/USDT/pump=6
                        final decimals = token.mint == wsolMint ? 9 : 6;
                        widget.onSelect(
                          token.mint,
                          token.symbol,
                          token.name,
                          token.imageUrl,
                          decimals,
                        );
                      },
                    ),
                  if (favorites.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'FAVORITES',
                        style: monoStyle(
                          fontSize: 10,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    ),
                    for (final fav in favorites)
                      // Skip if already in common tokens.
                      if (!commonTokens.any((c) => c.mint == fav.mint))
                        ListTile(
                          leading: TokenIcon(
                            imageUrl: fav.imageUrl,
                            mint: fav.mint,
                            symbol: fav.symbol ?? '?',
                            size: 36,
                          ),
                          title: Text(
                            fav.symbol ?? shortenAddress(fav.mint),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            fav.name ?? fav.mint,
                            style: TextStyle(
                              color: TibaneColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            widget.onSelect(
                              fav.mint,
                              fav.symbol ?? shortenAddress(fav.mint),
                              fav.name ?? fav.mint,
                              fav.imageUrl,
                              6,
                            );
                          },
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet shown after a successful swap. Displays the trade summary
/// (in → out with amounts), the on-chain signature with copy, an explorer
/// link if available, and a Done button.
class _SwapResultSheet extends StatelessWidget {
  final String signature;
  final String inputSymbol;
  final String outputSymbol;
  final double inputAmount;
  final double outputAmount;
  final String? explorerUrl;
  final String networkName;

  const _SwapResultSheet({
    required this.signature,
    required this.inputSymbol,
    required this.outputSymbol,
    required this.inputAmount,
    required this.outputAmount,
    required this.explorerUrl,
    required this.networkName,
  });

  /// Try a few launch modes so we don't silently no-op when the OS
  /// doesn't have a default browser registered for [externalApplication].
  /// Surface a snackbar on every failure path so testers see something.
  Future<void> _openExplorer(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      logError('[swap._openExplorer] invalid explorer URL: $url');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid explorer URL: $url')));
      return;
    }
    Object? lastErr;
    for (final mode in const [
      LaunchMode.externalApplication,
      LaunchMode.inAppBrowserView,
      LaunchMode.platformDefault,
    ]) {
      try {
        final ok = await launchUrl(uri, mode: mode);
        if (ok) return;
      } catch (e) {
        lastErr = e;
      }
    }
    logError('[swap._openExplorer] could not open $url: $lastErr');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          lastErr == null
              ? 'No app could open $url'
              : 'Could not open explorer: $lastErr',
        ),
      ),
    );
  }

  String _fmtAmount(double v) {
    if (v == 0) return '0';
    if (v >= 1) {
      // Up to 6 decimals, strip trailing zeros.
      var s = v.toStringAsFixed(6);
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      return s;
    }
    // Small numbers: more precision.
    var s = v.toStringAsFixed(8);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final shortSig = signature.length > 16
        ? '${signature.substring(0, 8)}…${signature.substring(signature.length - 8)}'
        : signature;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: TibaneColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: TibaneColors.cyan.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check,
                color: TibaneColors.cyan,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Swap submitted',
              style: TextStyle(
                color: TibaneColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Balance will update once the tx confirms on-chain.',
              style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: TibaneColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'YOU PAID',
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.textDim,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fmtAmount(inputAmount),
                          style: const TextStyle(
                            color: TibaneColors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          inputSymbol,
                          style: monoStyle(
                            fontSize: 11,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward,
                    color: TibaneColors.textDim,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'YOU GET',
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.textDim,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '~${_fmtAmount(outputAmount)}',
                          style: const TextStyle(
                            color: TibaneColors.cyan,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          outputSymbol,
                          style: monoStyle(
                            fontSize: 11,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TibaneColors.border),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    color: TibaneColors.textMuted,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SIGNATURE',
                          style: monoStyle(
                            fontSize: 9,
                            color: TibaneColors.textDim,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          shortSig,
                          style: monoStyle(
                            fontSize: 12,
                            color: TibaneColors.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: signature));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Signature copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (explorerUrl != null) ...[
              OutlinedButton.icon(
                onPressed: () => _openExplorer(context, explorerUrl!),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(
                  networkName.isNotEmpty
                      ? 'View on $networkName explorer'
                      : 'View on explorer',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: TibaneColors.text,
                  side: const BorderSide(color: TibaneColors.borderHover),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: const Size.fromHeight(0),
                ),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: TibaneColors.orange,
                foregroundColor: TibaneColors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size.fromHeight(0),
              ),
              child: const Text(
                'Done',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static "unavailable in your region" screen shown to UK users in place
/// of the swap form. Reachable in case a UK user navigates here from a
/// deep link or older shortcut. Points them to the browser tab for any
/// third-party DEX they want to use directly.
class _SwapUnavailableInRegion extends StatelessWidget {
  const _SwapUnavailableInRegion();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public_off, color: TibaneColors.textDim, size: 48),
            const SizedBox(height: 16),
            Text(
              'Swap not available in your region',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Tibane does not offer in-app token exchange in the United '
              'Kingdom. You can still use the in-app browser to access '
              'third-party services directly.',
              style: TextStyle(color: TibaneColors.textMuted, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
