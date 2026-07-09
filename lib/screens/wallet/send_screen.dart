import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart'
    show Amount, Asset, Network, NetworkType, TransactionSimulation;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../constants/solana_constants.dart';
import '../../services/balances_store.dart';
import '../../services/jupiter_service.dart';
import '../../services/wallet/send_asset.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import '../../widgets/network_logos.dart';
import '../../widgets/tibane_card.dart';
import '../../widgets/token_icon.dart';
import '../../widgets/tx_success.dart';
import 'widgets/authorize_and_sign.dart';
import '../../utils/amount.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Per-unit USD price for a token holding: the direct [priceUsd] when present,
/// else the fiat total ÷ balance (for chains that only report a value total),
/// else null. Pure, for unit-testing the send-screen USD estimate.
@visibleForTesting
double? holdingUnitPriceUsd({
  required double? priceUsd,
  required double? valueUsd,
  required double uiBalance,
}) {
  if (priceUsd != null) return priceUsd;
  if (valueUsd != null && uiBalance > 0) return valueUsd / uiBalance;
  return null;
}

/// Formats a USD amount for the send-screen estimate: `< $0.01` for dust,
/// K/M/B suffixes for large values, two decimals otherwise. Pure, for tests.
@visibleForTesting
String formatSendUsd(double v) {
  if (v > 0 && v < 0.01) return '< \$0.01';
  if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(2)}B';
  if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
  if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(2)}K';
  return '\$${v.toStringAsFixed(2)}';
}

/// Formats a send amount for the review sheet with the entered token's exact
/// [decimals] as the precision cap. Thin wrapper over the shared grouped
/// formatter (kept for the send-specific call sites + unit tests).
@visibleForTesting
String formatSendAmountGrouped(double v, int decimals) =>
    formatAmountGrouped(v, maxDecimals: decimals);

class SendScreen extends StatefulWidget {
  /// Optional SPL mint to send instead of native SOL. When null the
  /// screen behaves as a SOL transfer (the default).
  final String? mint;

  /// Ticker shown in the AppBar / amount label when [mint] is set.
  final String? symbol;

  /// On-chain decimals for [mint]. Required when [mint] is non-null
  /// — the scale of the amount input depends on it.
  final int? decimals;

  const SendScreen({super.key, this.mint, this.symbol, this.decimals});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _addrCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _sending = false;
  String? _error;

  // ENS / SNS resolution state for the recipient field.
  Timer? _resolveDebounce;
  String? _resolvingName;
  String? _resolvedAddress;
  String? _resolvedName;
  String? _resolveError;

  // Currently selected token. A null [_mint] means native SOL; non-null
  // is the SPL mint address. [_symbol] / [_decimals] / [_imageUrl] are
  // mirrored as state so the picker can update them without losing the
  // widget-supplied default.
  String? _mint;
  String _symbol = 'SOL';
  int _decimals = 9;
  String? _imageUrl;

  // Per-unit USD price of the native asset (Solana: the wSOL price from
  // Jupiter; other chains: derived from the native asset's fiat total). SPL /
  // token prices come from each [TokenHolding.priceUsd]. Drives the ~$ estimate
  // of the entered amount shown under the balance. Null until loaded / unknown.
  double? _nativePriceUsd;

  // The current account's network — drives the native asset's symbol/decimals
  // and the per-chain asset key so send is correct on every chain (Phase 5a).
  // Resolved authoritatively in _loadHoldings (the cached value can be stale).
  Network? _net;
  String _nativeSymbol = 'SOL';
  int _nativeDecimals = 9;

  // Tokens to offer in the picker. Solana SPL rows come from the shared
  // BalancesStore (read reactively in build); non-Solana rows are loaded here
  // from libwallet getAssets (chain-aware) into [_holdings], with [_assets]
  // also kept for the native balance.
  List<TokenHolding> _holdings = [];
  List<Asset> _assets = const [];
  bool _loadingHoldings = true;

  bool get _isSolana => (_net?.type ?? NetworkType.solana) == NetworkType.solana;

  @override
  void initState() {
    super.initState();
    _net = context.read<WalletService>().libwallet.currentNetwork;
    _mint = widget.mint;
    // Safe Solana-first defaults. _loadHoldings resolves the real network and
    // corrects native symbol/decimals per chain before the user can send — the
    // cached network here can be a stale default (Ethereum/18) and must NOT be
    // trusted for amount scaling.
    _symbol = widget.symbol ?? 'SOL';
    _decimals = widget.decimals ?? 9;
    _addrCtrl.addListener(_onAddrChanged);
    // Recompute the ~$ estimate as the amount changes — a listener (not the
    // field's onChanged) so it also fires when MAX sets the text programmatically.
    _amountCtrl.addListener(_onAmountChanged);
    _loadHoldings();
  }

  @override
  void dispose() {
    _addrCtrl.removeListener(_onAddrChanged);
    _amountCtrl.removeListener(_onAmountChanged);
    _resolveDebounce?.cancel();
    _addrCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHoldings() async {
    final wallet = context.read<WalletService>();
    final addr = wallet.publicKey;
    if (addr == null) {
      if (mounted) setState(() => _loadingHoldings = false);
      return;
    }
    // Resolve the REAL active network before deriving native decimals/symbol or
    // the asset key — the cached value can be a stale default and mis-scale the
    // amount (a SOL send scaled by 18 instead of 9).
    final net =
        await wallet.libwallet.refreshCurrentNetwork() ??
        wallet.libwallet.currentNetwork;
    if (!mounted) return;
    final type = net?.type.name ?? 'solana';
    final isSolana = type == 'solana';
    // Per-family fallback used until/unless the native asset's own decimals are
    // available. The authoritative source is the native Asset's Amount.exp
    // (resolved from getAssets below for non-Solana); Network.currencyDecimals
    // is deliberately NOT used (it can report 18 for Solana on a stale net).
    final fallbackDec = nativeDecimalsForType(type);
    final fallbackSym = isSolana
        ? 'SOL'
        : (net != null && net.currencySymbol.isNotEmpty
              ? net.currencySymbol
              : 'ETH');
    // Apply the resolved native metadata; update the live selection too when
    // it's the native asset (not a caller-specified token).
    void applyNative(int dec, String sym, VoidCallback rest) {
      setState(() {
        _net = net;
        _nativeSymbol = sym;
        _nativeDecimals = dec;
        if (widget.mint == null && _mint == null) {
          _symbol = sym;
          _decimals = dec;
        }
        rest();
      });
    }

    try {
      if (isSolana) {
        // Solana: SPL rows come from the shared BalancesStore (kept fresh by
        // the balance poller); build reads store.holdings. Native SOL is 9
        // decimals (the fallback constant is authoritative here). The wSOL
        // price is fetched for the native-send USD estimate (SPL rows carry
        // their own priceUsd from the store).
        final solPrice =
            (await JupiterService().fetchTokenPrices([wsolMint]))[wsolMint];
        if (!mounted) return;
        applyNative(fallbackDec, fallbackSym, () {
          _nativePriceUsd = solPrice;
          _loadingHoldings = false;
          // If opened for a specific SPL mint, pull its imageUrl from the
          // store's holdings so the selector chip shows a proper logo.
          if (_mint != null && _imageUrl == null) {
            for (final h in context.read<BalancesStore>().holdings) {
              if (h.mint == _mint) {
                _imageUrl = h.imageUrl;
                break;
              }
            }
          }
        });
      } else {
        // Non-Solana: libwallet getAssets is chain-aware. Its non-native
        // entries are the token rows; the native one feeds the balance AND the
        // authoritative native decimals (Amount.exp), with the constant as a
        // fallback only if the native asset hasn't surfaced yet.
        final assets = await wallet.libwallet.getAssets();
        if (!mounted) return;
        Asset? nativeAsset;
        for (final a in assets) {
          if (a.isNative && (net == null || a.network == net.id)) {
            nativeAsset = a;
            break;
          }
        }
        final dec = nativeAsset?.amount.exp ?? fallbackDec;
        final sym = (nativeAsset != null && nativeAsset.symbol.isNotEmpty)
            ? nativeAsset.symbol
            : fallbackSym;
        // Per-unit native price from the native asset's fiat total ÷ balance.
        final nativeUi = nativeAsset?.amount.toDouble() ?? 0;
        final nativeFiat = nativeAsset?.fiatAmount?.toDouble();
        final nativePrice = (nativeFiat != null && nativeUi > 0)
            ? nativeFiat / nativeUi
            : null;
        applyNative(dec, sym, () {
          _assets = assets;
          _nativePriceUsd = nativePrice;
          _holdings = [
            for (final a in assets)
              if (!a.isNative && (net == null || a.network == net.id))
                TokenHolding(
                  mint: mintFromAssetKey(a.key),
                  symbol: a.symbol.isNotEmpty ? a.symbol : a.name,
                  name: a.name,
                  balance: a.amount.value,
                  decimals: a.amount.exp,
                  uiBalance: a.amount.toDouble(),
                  valueUsd: a.fiatAmount?.toDouble(),
                ),
          ];
          _loadingHoldings = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingHoldings = false);
      debugPrint('[send] holdings load failed: $e');
    }
  }

  /// UI balance of the current account's native asset, per chain. Solana uses
  /// the cached SOL balance (populated before getAssets returns); other chains
  /// read the native entry from getAssets.
  double _nativeUiBalance(WalletService wallet) {
    final net = _net;
    if (net == null || net.type == NetworkType.solana) {
      return wallet.solBalance.toDouble() / 1e9;
    }
    for (final a in _assets) {
      if (a.isNative && a.network == net.id) return a.amount.toDouble();
    }
    return 0;
  }

  void _selectToken({
    required String? mint,
    required String symbol,
    required int decimals,
    String? imageUrl,
  }) {
    if (mint == _mint) return;
    setState(() {
      _mint = mint;
      _symbol = symbol;
      _decimals = decimals;
      _imageUrl = imageUrl;
      _amountCtrl.clear();
      _error = null;    });
  }

  Future<void> _openTokenPicker(List<TokenHolding> holdings) async {
    if (_sending) return;
    final wallet = context.read<WalletService>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SendTokenPicker(
        holdings: holdings,
        loading: _loadingHoldings,
        nativeSymbol: _nativeSymbol,
        nativeName: _isSolana ? 'Solana' : (_net?.name ?? _nativeSymbol),
        nativeDecimals: _nativeDecimals,
        nativeUiBalance: _nativeUiBalance(wallet),
        nativeIconMint: _isSolana ? wsolMint : '',
        selectedMint: _mint,
        onSelect: (mint, symbol, decimals, imageUrl) {
          Navigator.pop(ctx);
          _selectToken(
            mint: mint,
            symbol: symbol,
            decimals: decimals,
            imageUrl: imageUrl,
          );
        },
      ),
    );
  }

  void _onAddrChanged() {
    final raw = _addrCtrl.text.trim();
    // Only resolve when the input looks like a name (contains a dot and
    // isn't already a base58/0x-shaped address). Solana addresses are
    // 32-44 chars and don't contain dots, so a "." is a robust signal.
    final looksLikeName =
        raw.contains('.') && !raw.startsWith('0x') && raw.length < 64;
    if (!looksLikeName) {
      if (_resolvedAddress != null ||
          _resolvingName != null ||
          _resolveError != null) {
        setState(() {
          _resolvingName = null;
          _resolvedAddress = null;
          _resolvedName = null;
          _resolveError = null;
        });
      }
      return;
    }
    if (raw == _resolvedName || raw == _resolvingName) return;
    _resolveDebounce?.cancel();
    _resolveDebounce = Timer(const Duration(milliseconds: 350), () {
      _resolveName(raw);
    });
  }

  Future<void> _resolveName(String name) async {
    setState(() {
      _resolvingName = name;
      _resolvedAddress = null;
      _resolvedName = null;
      _resolveError = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final client = await wallet.libwallet.ensureClient();
      final r = await client.names.resolve(name);
      if (!mounted) return;
      // Only commit the result if the input is still the name we resolved
      // — otherwise the user kept typing and we should drop this answer.
      if (_addrCtrl.text.trim() != name) return;
      setState(() {
        _resolvingName = null;
        _resolvedName = name;
        _resolvedAddress = r.address;
      });
    } catch (e) {
      logError('[Send._resolveName] resolve "$name" error: $e');
      if (!mounted) return;
      if (_addrCtrl.text.trim() != name) return;
      setState(() {
        _resolvingName = null;
        _resolveError = 'Could not resolve $name';
      });
    }
  }

  Future<void> _setMax() async {
    final wallet = context.read<WalletService>();
    try {
      final result = await wallet.libwallet.maxSendable(
        to: _addrCtrl.text.trim().isNotEmpty ? _addrCtrl.text.trim() : null,
        asset: _assetKey,
      );
      if (!mounted) return;
      // result.max is an Amount scaled by the asset's decimals.
      final ui = result.max.toDouble();
      _amountCtrl.text = ui
          .toStringAsFixed(_decimals)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    } catch (e) {
      logError('[Send._setMax] max sendable error: $e');
      if (!mounted) return;
      setState(() => _error = WalletError.from(e).message);
    }
  }

  /// Asset key passed to libwallet for the selected token, derived per chain
  /// (`<type>.<chainId>.<mint>`); null for the native path. See [sendAssetKey].
  String? get _assetKey => sendAssetKey(
    mint: _mint,
    networkType: _net?.type.name ?? 'solana',
    chainId: _net?.chainId ?? 'mainnet',
  );

  Future<void> _send() async {
    final typed = _addrCtrl.text.trim();
    // If the user typed a name that resolved, use the resolved address.
    final addr = (typed == _resolvedName && _resolvedAddress != null)
        ? _resolvedAddress!
        : typed;
    if (addr.length < 32) {
      setState(() => _error = 'Enter a valid recipient address');
      return;
    }
    final amountFloat = parseAmount(_amountCtrl.text);
    if (amountFloat == null || amountFloat <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    final scale = BigInt.from(10).pow(_decimals);
    final raw = BigInt.from((amountFloat * scale.toDouble()).round());
    final amount = Amount(raw, _decimals);

    // Pre-flight: simulate before asking for the password / FaceID. This
    // catches "recipient_new_account" rent advice, "will revert" failures,
    // and surfaces the predicted balance changes to the user before any
    // keys come out.
    setState(() {
      _sending = true;
      _error = null;    });
    TransactionSimulation? sim;
    try {
      final wallet = context.read<WalletService>();
      sim = await wallet.libwallet.simulateSend(
        to: addr,
        amount: amount,
        asset: _assetKey,
      );
    } catch (e) {
      logError('[Send._send] simulate error: $e');
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = WalletError.from(e).message;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _sending = false);
    // Surface the human-readable name in the review sheet when the recipient
    // was entered as a resolved .sol / .eth name (else the sheet shows the
    // generic "Recipient" label above the address).
    final recipientName = (typed == _resolvedName && _resolvedAddress != null)
        ? _resolvedName
        : null;
    final approved = await _showReviewSheet(
      addr,
      amountFloat,
      sim,
      recipientName,
    );
    if (approved != true) return;
    if (!mounted) return;

    // Authorize the spend via the per-transaction sign sheet. In-app wallets
    // sign losslessly (no app-level unlock); MWA uses the swap-first layout and
    // never reaches this screen.
    final keys = await collectSigningKeys(context);
    if (keys == null) return; // cancelled / unsignable
    if (!mounted) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    final wallet = context.read<WalletService>();
    try {
      final tx = await wallet.libwallet.sendWithKeys(
        to: addr,
        amount: amount,
        asset: _assetKey,
        keys: keys,
      );
      if (!mounted) return;
      _amountCtrl.clear();
      // One post-tx trigger through the store: refreshes the dashboard's token
      // list + headline now and on the confirmation schedule, and (Solana)
      // confirms on-chain then reloads until the balance settles.
      context.read<BalancesStore>().onTxCommitted(tx.hash);
      // Replace the form with a full-screen success view (From / To / tx +
      // explorer link + share). Its own buttons own the return navigation.
      _showSuccessScreen(
        from: wallet.publicKey,
        to: addr,
        hash: tx.hash,
        amountUi: amountFloat,
      );
    } catch (e) {
      logError('[Send._send] send error: $e');
      if (!mounted) return;
      setState(() => _error = WalletError.from(e).message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Full-screen success view shown after a broadcast. Replaces the send form
  /// so the app-bar back arrow returns to wherever send was launched from;
  /// "Back to home" pops the tab stack to the dashboard.
  void _showSuccessScreen({
    required String? from,
    required String to,
    required String? hash,
    required double amountUi,
  }) {
    if (!mounted) return;
    final amountLabel =
        '${formatSendAmountGrouped(amountUi, _decimals)} $_symbol';
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _SendSuccessScreen(
          symbol: _symbol,
          amountLabel: amountLabel,
          fromAddress: from,
          toAddress: to,
          txHash: hash,
          net: _net,
        ),
      ),
    );
  }

  Future<bool?> _showReviewSheet(
    String to,
    double amountUi,
    TransactionSimulation sim,
    String? recipientName,
  ) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SendReviewSheet(
        to: to,
        recipientName: recipientName,
        amountUi: amountUi,
        symbol: _symbol,
        decimals: _decimals,
        imageUrl: _imageUrl,
        // Native SOL resolves its bundled logo via wsolMint; other chains'
        // natives fall back to the symbol placeholder. Mirrors _TokenSelector.
        iconMint: _mint ?? (_isSolana ? wsolMint : ''),
        net: _net,
        sim: sim,
      ),
    );
  }

  /// UI balance of the currently-selected token: native SOL from the
  /// (reactive) wallet balance, an SPL token from the loaded holdings.
  /// Null while SPL holdings are still loading / not found.
  double? _selectedBalance(WalletService wallet, List<TokenHolding> holdings) {
    if (_mint == null) return _nativeUiBalance(wallet);
    for (final h in holdings) {
      if (h.mint == _mint) return h.uiBalance;
    }
    return null;
  }

  String _fmtBalance(double b) {
    if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(2)}M';
    if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(2)}K';
    final s = b.toStringAsFixed(b >= 1 ? 4 : 6);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  /// Per-unit USD price of the selected token, or null when unknown. Native
  /// uses [_nativePriceUsd]; an SPL / token uses its holding via
  /// [holdingUnitPriceUsd].
  double? _selectedPriceUsd(List<TokenHolding> holdings) {
    if (_mint == null) return _nativePriceUsd;
    for (final h in holdings) {
      if (h.mint != _mint) continue;
      return holdingUnitPriceUsd(
        priceUsd: h.priceUsd,
        valueUsd: h.valueUsd,
        uiBalance: h.uiBalance,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final store = context.watch<BalancesStore>();
    // Solana SPL rows come from the shared store; non-Solana tokens are the
    // getAssets-derived rows loaded locally in _loadHoldings.
    final holdings = _isSolana ? store.holdings : _holdings;
    final selectedBalance = _selectedBalance(wallet, holdings);
    final price = _selectedPriceUsd(holdings);
    final amountUi = parseAmount(_amountCtrl.text);
    final usdValue = (price != null && amountUi != null && amountUi > 0)
        ? amountUi * price
        : null;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text('Send $_symbol')),
      body: SafeArea(
        child: GestureDetector(
          // Tap outside any input to dismiss the iOS numeric keyboard.
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: KeyboardSafeForm(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TokenSelector(
                  iconMint: _mint ?? (_isSolana ? wsolMint : ''),
                  symbol: _symbol,
                  imageUrl: _imageUrl,
                  loading: _loadingHoldings,
                  onTap: _sending ? null : () => _openTokenPicker(holdings),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _addrCtrl,
                  enabled: !_sending,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Recipient address or name',
                    labelStyle: const TextStyle(color: TibaneColors.textMuted),
                    helperText: 'Solana address, .sol name, or .eth name',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: _sending
                          ? null
                          : () async {
                              final clip = await Clipboard.getData(
                                'text/plain',
                              );
                              if (clip?.text != null)
                                _addrCtrl.text = clip!.text!;
                            },
                    ),
                  ),
                ),
                if (_resolvingName != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Resolving $_resolvingName…',
                        style: const TextStyle(
                          color: TibaneColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ] else if (_resolvedAddress != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: TibaneColors.cyan,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _resolvedAddress!,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(
                            fontSize: 12,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (_resolveError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _resolveError!,
                    style: const TextStyle(
                      color: TibaneColors.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _amountCtrl,
                  enabled: !_sending,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount ($_symbol)',
                    labelStyle: const TextStyle(color: TibaneColors.textMuted),
                    suffixIcon: TextButton(
                      onPressed: _sending ? null : _setMax,
                      child: const Text('MAX', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
                if (selectedBalance != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'Balance: ${_fmtBalance(selectedBalance)} $_symbol',
                      style: const TextStyle(
                        color: TibaneColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                if (usdValue != null) ...[
                  const SizedBox(height: 2),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '≈ ${formatSendUsd(usdValue)}',
                      style: const TextStyle(
                        color: TibaneColors.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: TibaneColors.error,
                      fontSize: 13,
                    ),
                  ),
                ],
                const Spacer(),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    _sending ? 'Sending...' : 'Send',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pre-broadcast review of an outgoing transfer. Leads with the token, the
/// amount, the recipient, and the network — then surfaces what libwallet's
/// `Transaction:simulate` predicts (will-revert flag, recipient rent, etc.)
/// before the user is asked to authenticate the send.
class _SendReviewSheet extends StatelessWidget {
  final String to;

  /// Resolved .sol / .eth name the recipient was entered as, shown as the
  /// pill above the address. Null falls back to the generic "Recipient" label.
  final String? recipientName;
  final double amountUi;
  final String symbol;
  final int decimals;

  /// Token-logo inputs, mirrored from the send screen so the review icon
  /// matches the selector (network `imageUrl` first, then bundled/mint logo).
  final String? imageUrl;
  final String iconMint;

  /// Active network — drives the "Network" card name + chain badge.
  final Network? net;
  final TransactionSimulation sim;

  const _SendReviewSheet({
    required this.to,
    required this.recipientName,
    required this.amountUi,
    required this.symbol,
    required this.decimals,
    required this.imageUrl,
    required this.iconMint,
    required this.net,
    required this.sim,
  });

  @override
  Widget build(BuildContext context) {
    final blocking =
        sim.willRevert || sim.warnings.any((w) => w.severity == 'block');
    final amountText = '${formatSendAmountGrouped(amountUi, decimals)} $symbol';
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TibaneColors.borderHover,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Review send',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'Please review the details before confirming this transaction.',
              textAlign: TextAlign.center,
              style: TextStyle(color: TibaneColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 28),
            // Token logo with a soft brand glow.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: TibaneColors.orange.withValues(alpha: 0.28),
                    blurRadius: 44,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: TokenIcon(
                imageUrl: imageUrl,
                mint: iconMint,
                symbol: symbol,
                size: 72,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              amountText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TibaneColors.text,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'To',
              style: TextStyle(color: TibaneColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            _recipientPill(recipientName ?? 'Recipient'),
            const SizedBox(height: 10),
            Text(
              to,
              textAlign: TextAlign.center,
              style: monoStyle(fontSize: 13, color: TibaneColors.text),
            ),
            const SizedBox(height: 22),
            if (net != null) _networkCard(net!),
            if (sim.willRevert) ...[
              const SizedBox(height: 14),
              _warning(
                TibaneColors.error,
                Icons.error_outline,
                'Simulation predicts this will fail: '
                '${sim.revertReason ?? "unknown error"}',
              ),
            ],
            for (final w in sim.warnings) ...[
              const SizedBox(height: 10),
              _warning(
                w.severity == 'block'
                    ? TibaneColors.error
                    : (w.severity == 'info'
                          ? TibaneColors.textMuted
                          : TibaneColors.gold),
                w.severity == 'block'
                    ? Icons.error_outline
                    : Icons.warning_amber_rounded,
                w.message.isNotEmpty ? w.message : w.code,
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TibaneColors.textMuted,
                      side: const BorderSide(color: TibaneColors.borderHover),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: blocking
                        ? null
                        : () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: TibaneColors.orange,
                      foregroundColor: TibaneColors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      blocking ? 'Cannot send' : 'Confirm',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _recipientPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: TibaneColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TibaneColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TibaneColors.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _networkCard(Network net) {
    final logoAsset = networkLogoAsset(net);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TibaneColors.darker,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TibaneColors.border),
      ),
      child: Row(
        children: [
          TokenIcon(
            imageUrl: imageUrl,
            mint: iconMint,
            symbol: symbol,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Network',
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 2),
                Text(
                  net.name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          if (logoAsset != null)
            Image.asset(
              logoAsset,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }

  Widget _warning(Color color, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
  }
}

/// Full-screen confirmation shown after a transfer is broadcast: a success
/// mark, the From / To / transaction details (each tap-to-copy), a link to the
/// chain explorer, and share + back-to-home actions.
class _SendSuccessScreen extends StatelessWidget {
  final String symbol;

  /// Pre-formatted amount ("10,000 FLASH") — used only in the shared receipt
  /// text; the reference success view itself doesn't restate the amount.
  final String amountLabel;
  final String? fromAddress;
  final String toAddress;
  final String? txHash;
  final Network? net;

  const _SendSuccessScreen({
    required this.symbol,
    required this.amountLabel,
    required this.fromAddress,
    required this.toAddress,
    required this.txHash,
    required this.net,
  });

  String _receiptText() {
    final b = StringBuffer('Sent $amountLabel\nTo: $toAddress');
    if (txHash != null) b.write('\nTransaction: $txHash');
    final url = explorerTxUrl(net, txHash);
    if (url != null) b.write('\n$url');
    return b.toString();
  }

  Future<void> _share(BuildContext context) async {
    try {
      await SharePlus.instance.share(ShareParams(text: _receiptText()));
    } catch (e) {
      logError('[SendSuccess._share] share error: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the share sheet')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = explorerTxUrl(net, txHash);
    final exName = net == null ? null : explorerNameFor(net!.type, net!.chainId);
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text('Send $symbol')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    const SizedBox(height: 36),
                    txSuccessMark(),
                    const SizedBox(height: 28),
                    const Text(
                      'Send successful',
                      style: TextStyle(
                        color: TibaneColors.text,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your $symbol transfer was completed.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: TibaneColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 32),
                    txReceiptCard(
                      icon: Icons.north_east,
                      label: 'From',
                      value: fromAddress ?? '—',
                      onTap: fromAddress == null
                          ? null
                          : () => copyWithToast(
                              context,
                              fromAddress!,
                              'Address',
                            ),
                    ),
                    const SizedBox(height: 12),
                    txReceiptCard(
                      icon: Icons.south_west,
                      label: 'To',
                      value: toAddress,
                      onTap: () => copyWithToast(context, toAddress, 'Address'),
                    ),
                    const SizedBox(height: 12),
                    txReceiptCard(
                      icon: Icons.receipt_long_outlined,
                      label: 'Transaction',
                      value: shortenTxHash(txHash) ?? '(unavailable)',
                      onTap: txHash == null
                          ? null
                          : () => copyWithToast(
                              context,
                              txHash!,
                              'Transaction ID',
                            ),
                      trailing: url == null
                          ? null
                          : txExplorerLink(
                              onTap: () => openExplorerUrl(context, url),
                              label: exName != null
                                  ? 'View on $exName'
                                  : 'View on explorer',
                            ),
                    ),
                    const SizedBox(height: 20),
                    if (txHash != null)
                      TextButton.icon(
                        onPressed: () => _share(context),
                        icon: const Icon(Icons.ios_share, size: 16),
                        style: TextButton.styleFrom(
                          foregroundColor: TibaneColors.textMuted,
                        ),
                        label: const Text('Share receipt'),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: txBackToHomeButton(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tap target at the top of the send screen showing which token is
/// active. Acts like a dropdown — pressing it opens the picker sheet.
class _TokenSelector extends StatelessWidget {
  final String iconMint;
  final String symbol;
  final String? imageUrl;
  final bool loading;
  final VoidCallback? onTap;

  const _TokenSelector({
    required this.iconMint,
    required this.symbol,
    required this.imageUrl,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Solana native uses wsolMint so the bundled sol.png logo wins; other
    // chains pass '' and fall back to the symbol placeholder.
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          TokenIcon(
            imageUrl: imageUrl,
            mint: iconMint,
            symbol: symbol,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOKEN',
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 2),
                Text(
                  symbol,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: TibaneColors.textMuted,
              ),
            )
          else
            const Icon(
              Icons.keyboard_arrow_down,
              size: 22,
              color: TibaneColors.textMuted,
            ),
        ],
      ),
    );
  }
}

/// Bottom-sheet list of tokens the user can send. Always renders a
/// native SOL row at the top (built from [solBalance]) followed by the
/// SPL holdings returned by Jupiter. Tapping a row reports the picked
/// token via [onSelect].
class _SendTokenPicker extends StatelessWidget {
  final List<TokenHolding> holdings;
  final bool loading;
  final String nativeSymbol;
  final String nativeName;
  final int nativeDecimals;
  final double nativeUiBalance;
  final String nativeIconMint;
  final String? selectedMint;

  /// `mint` is null for the native row, the token mint/contract otherwise.
  final void Function(
    String? mint,
    String symbol,
    int decimals,
    String? imageUrl,
  )
  onSelect;

  const _SendTokenPicker({
    required this.holdings,
    required this.loading,
    required this.nativeSymbol,
    required this.nativeName,
    required this.nativeDecimals,
    required this.nativeUiBalance,
    required this.nativeIconMint,
    required this.selectedMint,
    required this.onSelect,
  });

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
                  'Select token to send',
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
              itemCount: holdings.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _row(
                    mint: null,
                    symbol: nativeSymbol,
                    name: nativeName,
                    imageUrl: null,
                    iconMint: nativeIconMint,
                    decimals: nativeDecimals,
                    uiBalance: nativeUiBalance,
                    valueUsd: null,
                    selected: selectedMint == null,
                  );
                }
                final h = holdings[index - 1];
                return _row(
                  mint: h.mint,
                  symbol: h.symbol.isNotEmpty ? h.symbol : h.name,
                  name: h.name,
                  imageUrl: h.imageUrl,
                  iconMint: h.mint,
                  decimals: h.decimals,
                  uiBalance: h.uiBalance,
                  valueUsd: h.valueUsd,
                  selected: selectedMint == h.mint,
                );
              },
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TibaneColors.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row({
    required String? mint,
    required String symbol,
    required String name,
    required String? imageUrl,
    required String iconMint,
    required int decimals,
    required double uiBalance,
    required double? valueUsd,
    required bool selected,
  }) {
    return ListTile(
      leading: TokenIcon(
        imageUrl: imageUrl,
        mint: iconMint,
        symbol: symbol,
        size: 36,
      ),
      title: Row(
        children: [
          Text(
            symbol,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check, size: 14, color: TibaneColors.cyan),
          ],
        ],
      ),
      subtitle: name.isNotEmpty && name != symbol
          ? Text(
              name,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 12,
              ),
            )
          : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatBalance(uiBalance),
            style: monoStyle(fontSize: 12),
          ),
          if (valueUsd != null)
            Text(
              '\$${valueUsd.toStringAsFixed(2)}',
              style: monoStyle(fontSize: 10, color: TibaneColors.textMuted),
            ),
        ],
      ),
      onTap: () => onSelect(mint, symbol, decimals, imageUrl),
    );
  }

  String _formatBalance(double balance) {
    if (balance >= 1e6) return '${(balance / 1e6).toStringAsFixed(2)}M';
    if (balance >= 1e3) return '${(balance / 1e3).toStringAsFixed(2)}K';
    if (balance >= 1) return balance.toStringAsFixed(4);
    return balance.toStringAsFixed(6);
  }
}
