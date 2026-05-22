import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dart:typed_data';

import '../constants/solana_constants.dart';
import '../models/token_account.dart';
import '../services/domain_instructions.dart';
import '../services/nft_instructions.dart';
import '../services/relay_service.dart';
import '../services/rpc_service.dart';
import '../services/solana_common.dart';
import '../services/spl_instructions.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import 'wallet/inapp_unlock_screen.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';

class IncineratorScreen extends StatefulWidget {
  const IncineratorScreen({super.key});

  @override
  State<IncineratorScreen> createState() => _IncineratorScreenState();
}

class _IncineratorScreenState extends State<IncineratorScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _rpc = RpcService();
  final _relay = RelayService();
  WalletService? _wallet;

  // Token state
  List<TokenAccount> _tokenAccounts = [];
  bool _loadingTokens = false;

  // NFT state
  List<NftItem> _nfts = [];
  bool _loadingNfts = false;

  // Domain state
  List<DomainItem> _domains = [];
  bool _loadingDomains = false;

  bool _burning = false;
  String? _error;

  // Sponsored burn settings
  bool _sponsoredMode = true;
  double _tipPercent =
      5.0; // 0 = minimum (relay keeps fees only), 100 = user gives all rent
  int _sponsoredCurrent = 0;
  int _sponsoredTotal = 0;

  bool _walletWasConnected = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    final wallet = context.read<WalletService>();
    _wallet = wallet;
    wallet.addListener(_onWalletChanged);
    if (wallet.isConnected) {
      _walletWasConnected = true;
      _loadAll();
    }
  }

  void _onWalletChanged() {
    final wallet = context.read<WalletService>();
    if (wallet.isConnected && !_walletWasConnected) {
      _walletWasConnected = true;
      _loadAll();
    } else if (!wallet.isConnected && _walletWasConnected) {
      _walletWasConnected = false;
      setState(() {
        _tokenAccounts = [];
        _nfts = [];
        _domains = [];
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _wallet?.removeListener(_onWalletChanged);
    _tabController.dispose();
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    _loadTokens();
    _loadNfts();
    _loadDomains();
  }

  Future<void> _loadTokens() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() {
      _loadingTokens = true;
      _error = null;
    });

    try {
      final splAccounts = await _rpc.getTokenAccountsByOwner(wallet.publicKey!);
      final t22Accounts = await _rpc.getTokenAccountsByOwner(
        wallet.publicKey!,
        token2022: true,
      );
      final allAccounts = [...splAccounts, ...t22Accounts];

      final mints = allAccounts.map((a) => a.mint).toSet().toList();
      if (mints.isNotEmpty) {
        for (var i = 0; i < mints.length; i += 100) {
          final batch = mints.sublist(
            i,
            i + 100 > mints.length ? mints.length : i + 100,
          );
          final metadata = await _rpc.getAssetBatch(batch);
          for (final account in allAccounts) {
            final meta = metadata[account.mint];
            if (meta != null) {
              account.name = meta.name;
              account.symbol = meta.symbol;
              account.imageUrl = meta.imageUrl;
              account.usdPrice = meta.pricePerToken;
            }
          }
        }
      }

      setState(() {
        _tokenAccounts = allAccounts;
        _loadingTokens = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load tokens: $e';
        _loadingTokens = false;
      });
    }
  }

  Future<void> _loadNfts() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() => _loadingNfts = true);

    try {
      final assets = await _rpc.getAssetsByOwner(wallet.publicKey!);
      final nfts = <NftItem>[];

      for (final asset in assets) {
        final iface = asset['interface'] as String? ?? '';
        // Only include NFT-like interfaces
        if (!['V1_NFT', 'V1_PRINT', 'ProgrammableNFT'].contains(iface))
          continue;
        nfts.add(NftItem.fromHeliusAsset(asset));
      }

      setState(() {
        _nfts = nfts;
        _loadingNfts = false;
      });
    } catch (e) {
      setState(() => _loadingNfts = false);
    }
  }

  Future<void> _loadDomains() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() => _loadingDomains = true);

    try {
      final assets = await _rpc.getAssetsByOwner(wallet.publicKey!);
      final domains = <DomainItem>[];

      for (final asset in assets) {
        final content = asset['content'] as Map<String, dynamic>?;
        final metadata = content?['metadata'] as Map<String, dynamic>?;
        final name = metadata?['name'] as String? ?? '';
        if (name.endsWith('.sol')) {
          domains.add(DomainItem(id: asset['id'] as String? ?? '', name: name));
        }
      }

      setState(() {
        _domains = domains;
        _loadingDomains = false;
      });
    } catch (e) {
      setState(() => _loadingDomains = false);
    }
  }

  // Selection helpers
  List<TokenAccount> get _selectedTokens =>
      _tokenAccounts.where((a) => a.selected).toList();
  List<NftItem> get _selectedNfts => _nfts.where((n) => n.selected).toList();
  List<DomainItem> get _selectedDomains =>
      _domains.where((d) => d.selected).toList();

  int get _selectedCount =>
      _selectedTokens.length + _selectedNfts.length + _selectedDomains.length;

  BigInt get _reclaimableSol {
    var total = BigInt.zero;
    for (final a in _selectedTokens) {
      total += a.rentLamports;
    }
    for (final n in _selectedNfts) {
      total += BigInt.from(n.rentLamports);
    }
    for (final d in _selectedDomains) {
      total += BigInt.from(d.rentLamports);
    }
    return total;
  }

  void _toggleAllTokens(bool? selected) {
    setState(() {
      for (final a in _tokenAccounts) {
        a.selected = selected ?? false;
      }
    });
  }

  void _toggleAllNfts(bool? selected) {
    setState(() {
      for (final n in _nfts) {
        n.selected = selected ?? false;
      }
    });
  }

  void _toggleAllDomains(bool? selected) {
    setState(() {
      for (final d in _domains) {
        d.selected = selected ?? false;
      }
    });
  }

  /// Per-item rounding: user receive amount is rounded per item.
  /// tipPercent 0 = minimum tip (relay just covers fees), 100 = user gives all rent.
  int _userReceiveLamports(List<int> itemRents) {
    var total = 0;
    for (final rent in itemRents) {
      total += ((rent * (100 - _tipPercent) / 100 / 100000).round()) * 100000;
    }
    return total;
  }

  int _calculateTipLamports(List<int> itemRents) {
    final totalRent = itemRents.fold(0, (s, r) => s + r);
    final tip = totalRent - _userReceiveLamports(itemRents);
    return tip > 0 ? tip : 0;
  }

  Future<void> _burnSelected() async {
    // Confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Confirm Burn'),
        content: Text(
          'Burn $_selectedCount selected item${_selectedCount == 1 ? '' : 's'}? This cannot be undone.',
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Burn',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // In-app wallet must be unlocked before signing — otherwise
    // `signTransaction` returns null and the user gets a useless
    // "Wallet is locked" toast. Route to the unlock screen first.
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;

    if (_sponsoredMode) {
      await _sponsoredBurn();
    } else {
      await _directBurn();
    }
  }

  Future<void> _partialBurn(TokenAccount account) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: Text('Burn ${account.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Balance: ${formatTokenAmount(account.amount, account.decimals)}',
              style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(hintText: 'Amount to burn'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                final v =
                    account.amount.toDouble() /
                    BigInt.from(10).pow(account.decimals).toDouble();
                controller.text = v.toStringAsFixed(account.decimals);
              },
              child: Text(
                'MAX',
                style: monoStyle(fontSize: 11, color: TibaneColors.orange),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(
              'Burn',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirmed == null || confirmed.isEmpty) return;
    final v = double.tryParse(confirmed);
    if (v == null || v <= 0) return;
    final amount = BigInt.from(
      v * BigInt.from(10).pow(account.decimals).toDouble(),
    );
    if (amount <= BigInt.zero) return;

    if (!mounted) return;
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!await InAppUnlockScreen.ensureUnlocked(context)) return;

    setState(() => _burning = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final tokenProgramId = account.isToken2022
          ? token2022ProgramId
          : splTokenProgramId;
      final ix = createBurnCheckedIx(
        tokenAccount: account.pubkey,
        mint: account.mint,
        authority: wallet.publicKey!,
        amount: amount,
        decimals: account.decimals,
        tokenProgramId: tokenProgramId,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
      if (!mounted) return;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Burned: ${sig.substring(0, 8)}...')),
        );
        await _rpc.confirmTransaction(sig);
        if (!mounted) return;
        _loadTokens();
        wallet.refreshBalances();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _burning = false);
    }
  }

  void _clearSelection() {
    for (final a in _tokenAccounts) {
      a.selected = false;
    }
    for (final n in _nfts) {
      n.selected = false;
    }
    for (final d in _domains) {
      d.selected = false;
    }
  }

  /// Direct burn: user pays fees, sign & send
  Future<void> _directBurn() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() => _burning = true);

    String? lastSig;
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      var successCount = 0;

      // Burn tokens (batch 5 per tx)
      final tokens = _selectedTokens.toList();
      for (var i = 0; i < tokens.length; i += 5) {
        final batch = tokens.sublist(
          i,
          i + 5 > tokens.length ? tokens.length : i + 5,
        );
        final instructions = <SolanaInstruction>[];
        for (final account in batch) {
          instructions.addAll(
            buildBurnAndCloseInstructions(
              tokenAccount: account.pubkey,
              mint: account.mint,
              owner: wallet.publicKey!,
              amount: account.amount,
              decimals: account.decimals,
              isToken2022: account.isToken2022,
            ),
          );
        }
        final tx = buildTransaction(
          recentBlockhash: blockhash,
          feePayer: wallet.publicKey!,
          instructions: instructions,
        );
        final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
        if (sig != null) {
          successCount += batch.length;
          lastSig = sig;
        } else {
          break;
        }
      }

      // Burn regular NFTs (batch 3 per tx)
      final regularNfts = _selectedNfts
          .where((n) => !n.compressed && n.mint != null)
          .toList();
      for (var i = 0; i < regularNfts.length; i += 3) {
        final batch = regularNfts.sublist(
          i,
          i + 3 > regularNfts.length ? regularNfts.length : i + 3,
        );
        final instructions = batch
            .map((n) => buildRegularNftBurnIx(n, wallet.publicKey!))
            .toList();
        final tx = buildTransaction(
          recentBlockhash: blockhash,
          feePayer: wallet.publicKey!,
          instructions: instructions,
        );
        final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
        if (sig != null) {
          successCount += batch.length;
          lastSig = sig;
        } else {
          break;
        }
      }

      // Burn cNFTs (1 per tx)
      final cNfts = _selectedNfts.where((n) => n.compressed).toList();
      for (final nft in cNfts) {
        final proof = await _rpc.getAssetProof(nft.id);
        if (proof == null) continue;
        final ix = buildCnftBurnIx(nft, wallet.publicKey!, proof);
        final tx = buildTransaction(
          recentBlockhash: blockhash,
          feePayer: wallet.publicKey!,
          instructions: [ix],
        );
        final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
        if (sig != null) {
          successCount++;
          lastSig = sig;
        } else {
          break;
        }
      }

      // Delete domains (batch 25 per tx)
      final domains = _selectedDomains.toList();
      for (var i = 0; i < domains.length; i += 25) {
        final batch = domains.sublist(
          i,
          i + 25 > domains.length ? domains.length : i + 25,
        );
        final instructions = batch
            .map(
              (d) => buildDomainDeleteIx(
                nameAccount: d.id,
                owner: wallet.publicKey!,
              ),
            )
            .toList();
        final tx = buildTransaction(
          recentBlockhash: blockhash,
          feePayer: wallet.publicKey!,
          instructions: instructions,
        );
        final sig = await wallet.signAndSendTransaction(Uint8List.fromList(tx));
        if (sig != null) {
          successCount += batch.length;
          lastSig = sig;
        } else {
          break;
        }
      }

      if (!mounted) return;
      if (successCount > 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Burned $successCount items')));
        _clearSelection();
      } else if (wallet.error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(wallet.error!)));
        wallet.clearError();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _burning = false);
      if (lastSig != null) {
        await _rpc.confirmTransaction(lastSig);
      }
      if (mounted) {
        _loadAll();
        wallet.refreshBalances();
      }
    }
  }

  /// Sponsored burn: relayer pays fees, user signs only, relay submits.
  /// Matches tibanenet IncineratorView.vue executeCombinedSponsoredBurn().
  Future<void> _sponsoredBurn() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;

    setState(() {
      _burning = true;
      _sponsoredCurrent = 0;
      _sponsoredTotal = 0;
    });

    String? lastSig;
    try {
      final owner = wallet.publicKey!;
      final feePayer = relayerAddress;

      // Gather all work items: (instructions, rent) pairs
      final items = <({List<SolanaInstruction> ixs, int rent})>[];

      for (final account in _selectedTokens) {
        items.add((
          ixs: buildBurnAndCloseInstructions(
            tokenAccount: account.pubkey,
            mint: account.mint,
            owner: owner,
            amount: account.amount,
            decimals: account.decimals,
            isToken2022: account.isToken2022,
          ),
          rent: account.rentLamports.toInt(),
        ));
      }

      final regularNfts = _selectedNfts
          .where((n) => !n.compressed && n.mint != null)
          .toList();
      for (final nft in regularNfts) {
        items.add((
          ixs: [buildRegularNftBurnIx(nft, owner)],
          rent: nft.rentLamports,
        ));
      }

      for (final domain in _selectedDomains) {
        items.add((
          ixs: [buildDomainDeleteIx(nameAccount: domain.id, owner: owner)],
          rent: domain.rentLamports,
        ));
      }

      // Pack items into size-capped batches (matching web app's buildMixedBatches)
      final blockhash = await _rpc.getLatestBlockhash();
      final batches = <(List<SolanaInstruction>, List<int>)>[];
      var currentIxs = <SolanaInstruction>[];
      var currentRents = <int>[];

      for (final item in items) {
        // Probe: would adding this item exceed max tx size?
        final probeIxs = [...currentIxs, ...item.ixs];
        final probeRents = [...currentRents, item.rent];
        final tipLamports = _calculateTipLamports(probeRents);
        final probeFull = [...probeIxs];
        if (tipLamports > 0) {
          probeFull.add(
            createSystemTransferIx(
              from: owner,
              to: feePayer,
              lamports: BigInt.from(tipLamports),
            ),
          );
        }
        final probeSize = buildTransaction(
          recentBlockhash: blockhash,
          feePayer: feePayer,
          instructions: probeFull,
        ).length;

        if (currentIxs.isNotEmpty && probeSize > 1180) {
          // Finalize current batch
          final tip = _calculateTipLamports(currentRents);
          if (tip > 0) {
            currentIxs.add(
              createSystemTransferIx(
                from: owner,
                to: feePayer,
                lamports: BigInt.from(tip),
              ),
            );
          }
          batches.add((currentIxs, currentRents));
          currentIxs = [];
          currentRents = [];
        }
        currentIxs.addAll(item.ixs);
        currentRents.add(item.rent);
      }
      if (currentIxs.isNotEmpty) {
        final tip = _calculateTipLamports(currentRents);
        if (tip > 0) {
          currentIxs.add(
            createSystemTransferIx(
              from: owner,
              to: feePayer,
              lamports: BigInt.from(tip),
            ),
          );
        }
        batches.add((currentIxs, currentRents));
      }

      // cNFTs: 1 per tx, no tip (0 rent)
      final cNfts = _selectedNfts.where((n) => n.compressed).toList();
      for (final nft in cNfts) {
        final proof = await _rpc.getAssetProof(nft.id);
        if (proof == null) continue;
        batches.add(([buildCnftBurnIx(nft, owner, proof)], [0]));
      }

      setState(() => _sponsoredTotal = batches.length);

      final signatures = <String>[];
      for (final (ixs, _) in batches) {
        final freshHash = await _rpc.getLatestBlockhash();
        final txBytes = buildTransaction(
          recentBlockhash: freshHash,
          feePayer: feePayer,
          instructions: ixs,
        );

        // Simulate first to catch errors with useful context
        debugPrint(
          '[SponsoredBurn] tx size=${txBytes.length}, feePayer=$feePayer, owner=$owner',
        );
        debugPrint(
          '[SponsoredBurn] numSignatures=${txBytes[0]}, instructions=${ixs.length}',
        );
        debugPrint('[SponsoredBurn] tx_b64=${base64Encode(txBytes)}');
        try {
          final simResult = await _rpc.simulateTransaction(
            Uint8List.fromList(txBytes),
          );
          final simErr = simResult['err'];
          if (simErr != null) {
            debugPrint('[SponsoredBurn] Simulation error: $simErr');
            debugPrint('[SponsoredBurn] Logs: ${simResult['logs']}');
            throw Exception('Simulation failed: $simErr');
          }
          debugPrint('[SponsoredBurn] Simulation OK');
        } catch (e) {
          debugPrint('[SponsoredBurn] Simulation exception: $e');
          // Continue to try signing even if sim fails (relay might handle differently)
        }

        // Sign only — relay adds fee payer signature and submits
        final signed = await wallet.signTransaction(
          Uint8List.fromList(txBytes),
        );
        if (signed == null) {
          debugPrint(
            '[SponsoredBurn] signTransaction returned null, wallet error: ${wallet.error}',
          );
          if (mounted && wallet.error != null) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Wallet: ${wallet.error}')));
            wallet.clearError();
          }
          break;
        }
        final sig = await _relay.relay(signed);
        signatures.add(sig);
        lastSig = sig;
        setState(() => _sponsoredCurrent++);
      }

      if (!mounted) return;
      if (signatures.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Burned ${signatures.length} batches via relay'),
          ),
        );
        _clearSelection();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _burning = false);
      // Wait for the last submitted tx to confirm before reloading. Without
      // this, RPC returns pre-burn state and the just-burned accounts and
      // balances appear unchanged in the UI.
      if (lastSig != null) {
        await _rpc.confirmTransaction(lastSig);
      }
      if (mounted) {
        _loadAll();
        wallet.refreshBalances();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final anyLoading = _loadingTokens || _loadingNfts || _loadingDomains;

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.local_fire_department,
                  color: TibaneColors.orange,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Incinerator',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'Burn tokens, NFTs & domains',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (wallet.isConnected)
                IconButton(
                  onPressed: anyLoading ? null : _loadAll,
                  icon: const Icon(Icons.refresh, size: 20),
                  color: TibaneColors.textMuted,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Tabs
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: TibaneColors.darker,
            borderRadius: BorderRadius.circular(8),
          ),
          child: TabBar(
            controller: _tabController,
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            indicator: BoxDecoration(
              color: TibaneColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TibaneColors.border),
            ),
            tabs: [
              Tab(
                text: _loadingTokens
                    ? 'Tokens ...'
                    : 'Tokens (${_tokenAccounts.length})',
              ),
              Tab(text: _loadingNfts ? 'NFTs ...' : 'NFTs (${_nfts.length})'),
              Tab(
                text: _loadingDomains
                    ? 'Domains ...'
                    : 'Domains (${_domains.length})',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Content
        Expanded(
          child: !wallet.isConnected
              ? _NotConnectedView()
              : _error != null
              ? _ErrorView(error: _error!, onRetry: _loadAll)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _loadingTokens
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: TibaneColors.orange,
                            ),
                          )
                        : RefreshIndicator(
                            color: TibaneColors.orange,
                            onRefresh: _loadTokens,
                            child: _TokensList(
                              accounts: _tokenAccounts,
                              onToggle: (account) => setState(
                                () => account.selected = !account.selected,
                              ),
                              onToggleAll: _toggleAllTokens,
                              onPartialBurn: _partialBurn,
                            ),
                          ),
                    _loadingNfts
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: TibaneColors.orange,
                            ),
                          )
                        : RefreshIndicator(
                            color: TibaneColors.orange,
                            onRefresh: _loadNfts,
                            child: _NftsList(
                              nfts: _nfts,
                              onToggle: (nft) =>
                                  setState(() => nft.selected = !nft.selected),
                              onToggleAll: _toggleAllNfts,
                            ),
                          ),
                    _loadingDomains
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: TibaneColors.orange,
                            ),
                          )
                        : RefreshIndicator(
                            color: TibaneColors.orange,
                            onRefresh: _loadDomains,
                            child: _DomainsList(
                              domains: _domains,
                              onToggle: (domain) => setState(
                                () => domain.selected = !domain.selected,
                              ),
                              onToggleAll: _toggleAllDomains,
                            ),
                          ),
                  ],
                ),
        ),
        // Bottom action bar
        if (wallet.isConnected && _selectedCount > 0)
          _BottomBar(
            selectedCount: _selectedCount,
            reclaimableSol: _reclaimableSol,
            burning: _burning,
            sponsoredMode: _sponsoredMode,
            tipPercent: _tipPercent,
            sponsoredCurrent: _sponsoredCurrent,
            sponsoredTotal: _sponsoredTotal,
            onBurn: _burnSelected,
            onToggleSponsored: (v) => setState(() => _sponsoredMode = v),
            onTipChanged: (v) => setState(() => _tipPercent = v),
          ),
      ],
    );
  }
}

class _NotConnectedView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 48,
              color: TibaneColors.textDim,
            ),
            const SizedBox(height: 16),
            Text(
              'Connect your wallet to view your tokens',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: TibaneColors.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
              color: TibaneColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              error,
              style: const TextStyle(color: TibaneColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _TokensList extends StatelessWidget {
  final List<TokenAccount> accounts;
  final void Function(TokenAccount) onToggle;
  final void Function(bool?) onToggleAll;
  final void Function(TokenAccount)? onPartialBurn;

  const _TokensList({
    required this.accounts,
    required this.onToggle,
    required this.onToggleAll,
    this.onPartialBurn,
  });

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 240,
            child: Center(
              child: Text(
                'No token accounts found',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ),
        ],
      );
    }

    final emptyAccounts = accounts.where((a) => a.isEmpty).toList();
    final nonEmptyAccounts = accounts.where((a) => !a.isEmpty).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Row(
          children: [
            Checkbox(
              value: accounts.every((a) => a.selected)
                  ? true
                  : accounts.any((a) => a.selected)
                  ? null
                  : false,
              tristate: true,
              onChanged: onToggleAll,
              activeColor: TibaneColors.orange,
            ),
            Text(
              '${accounts.length} accounts',
              style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
            ),
            const Spacer(),
            Text(
              '${emptyAccounts.length} empty',
              style: monoStyle(fontSize: 12, color: TibaneColors.textDim),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (emptyAccounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'EMPTY ACCOUNTS',
              style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
            ),
          ),
          ...emptyAccounts.map(
            (a) => _TokenAccountTile(account: a, onToggle: () => onToggle(a)),
          ),
          const SizedBox(height: 16),
        ],
        if (nonEmptyAccounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'TOKENS',
              style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
            ),
          ),
          ...nonEmptyAccounts.map(
            (a) => _TokenAccountTile(
              account: a,
              onToggle: () => onToggle(a),
              onLongPress: onPartialBurn != null
                  ? () => onPartialBurn!(a)
                  : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _TokenAccountTile extends StatelessWidget {
  final TokenAccount account;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;

  const _TokenAccountTile({
    required this.account,
    required this.onToggle,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onLongPress: !account.isEmpty ? onLongPress : null,
        child: TibaneCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: onToggle,
          child: Row(
            children: [
              Checkbox(
                value: account.selected,
                onChanged: (_) => onToggle(),
                activeColor: TibaneColors.orange,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: TibaneColors.darker,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: account.imageUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          account.imageUrl!,
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          errorBuilder: (_, e, s) => const Icon(
                            Icons.token,
                            size: 18,
                            color: TibaneColors.textDim,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.token,
                        size: 18,
                        color: TibaneColors.textDim,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName,
                      style: const TextStyle(
                        color: TibaneColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      account.isEmpty
                          ? 'Empty account'
                          : formatTokenAmount(account.amount, account.decimals),
                      style: monoStyle(
                        fontSize: 11,
                        color: account.isEmpty
                            ? TibaneColors.textDim
                            : TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${account.rentSol.toStringAsFixed(4)} SOL',
                    style: monoStyle(fontSize: 11, color: TibaneColors.gold),
                  ),
                  if (account.usdPrice != null && !account.isEmpty)
                    Text(
                      '\$${(account.displayAmount * account.usdPrice!).toStringAsFixed(2)}',
                      style: monoStyle(
                        fontSize: 9,
                        color: TibaneColors.textDim,
                      ),
                    ),
                  if (account.isToken2022)
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: TibaneColors.purple.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        'T22',
                        style: monoStyle(
                          fontSize: 8,
                          color: TibaneColors.purple,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NftsList extends StatelessWidget {
  final List<NftItem> nfts;
  final void Function(NftItem) onToggle;
  final void Function(bool?) onToggleAll;

  const _NftsList({
    required this.nfts,
    required this.onToggle,
    required this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    if (nfts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 240,
            child: Center(
              child: Text(
                'No NFTs found',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        Row(
          children: [
            Checkbox(
              value: nfts.every((n) => n.selected)
                  ? true
                  : nfts.any((n) => n.selected)
                  ? null
                  : false,
              tristate: true,
              onChanged: onToggleAll,
              activeColor: TibaneColors.orange,
            ),
            Text(
              '${nfts.length} NFTs',
              style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
            ),
            const Spacer(),
            Text(
              '${nfts.where((n) => n.compressed).length} compressed',
              style: monoStyle(fontSize: 12, color: TibaneColors.textDim),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...nfts.map((n) => _NftTile(nft: n, onToggle: () => onToggle(n))),
      ],
    );
  }
}

class _NftTile extends StatelessWidget {
  final NftItem nft;
  final VoidCallback onToggle;

  const _NftTile({required this.nft, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TibaneCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onToggle,
        child: Row(
          children: [
            Checkbox(
              value: nft.selected,
              onChanged: (_) => onToggle(),
              activeColor: TibaneColors.orange,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: nft.image != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        nft.image!,
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                        errorBuilder: (_, e, s) => const Icon(
                          Icons.image,
                          size: 18,
                          color: TibaneColors.textDim,
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.image,
                      size: 18,
                      color: TibaneColors.textDim,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nft.name,
                    style: const TextStyle(
                      color: TibaneColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (nft.collection != null)
                    Text(
                      shortenAddress(nft.collection!, chars: 4),
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (nft.rentLamports > 0)
                  Text(
                    '${(nft.rentLamports / 1e9).toStringAsFixed(4)} SOL',
                    style: monoStyle(fontSize: 11, color: TibaneColors.gold),
                  ),
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (nft.compressed
                                ? TibaneColors.cyan
                                : TibaneColors.purple)
                            .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    nft.compressed ? 'cNFT' : 'NFT',
                    style: monoStyle(
                      fontSize: 8,
                      color: nft.compressed
                          ? TibaneColors.cyan
                          : TibaneColors.purple,
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
}

class _DomainsList extends StatelessWidget {
  final List<DomainItem> domains;
  final void Function(DomainItem) onToggle;
  final void Function(bool?) onToggleAll;

  const _DomainsList({
    required this.domains,
    required this.onToggle,
    required this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    if (domains.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 240,
            child: Center(
              child: Text(
                'No domains found',
                style: TextStyle(color: TibaneColors.textMuted),
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Row(
          children: [
            Checkbox(
              value: domains.every((d) => d.selected)
                  ? true
                  : domains.any((d) => d.selected)
                  ? null
                  : false,
              tristate: true,
              onChanged: onToggleAll,
              activeColor: TibaneColors.orange,
            ),
            Text(
              '${domains.length} domains',
              style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...domains.map(
          (d) => _DomainTile(domain: d, onToggle: () => onToggle(d)),
        ),
      ],
    );
  }
}

class _DomainTile extends StatelessWidget {
  final DomainItem domain;
  final VoidCallback onToggle;

  const _DomainTile({required this.domain, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TibaneCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: onToggle,
        child: Row(
          children: [
            Checkbox(
              value: domain.selected,
              onChanged: (_) => onToggle(),
              activeColor: TibaneColors.orange,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.language,
                size: 18,
                color: TibaneColors.textDim,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                domain.name,
                style: const TextStyle(
                  color: TibaneColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${(domain.rentLamports / 1e9).toStringAsFixed(4)} SOL',
              style: monoStyle(fontSize: 11, color: TibaneColors.gold),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int selectedCount;
  final BigInt reclaimableSol;
  final bool burning;
  final bool sponsoredMode;
  final double tipPercent;
  final int sponsoredCurrent;
  final int sponsoredTotal;
  final VoidCallback onBurn;
  final ValueChanged<bool> onToggleSponsored;
  final ValueChanged<double> onTipChanged;

  const _BottomBar({
    required this.selectedCount,
    required this.reclaimableSol,
    required this.burning,
    required this.sponsoredMode,
    required this.tipPercent,
    required this.sponsoredCurrent,
    required this.sponsoredTotal,
    required this.onBurn,
    required this.onToggleSponsored,
    required this.onTipChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: TibaneColors.dark,
        border: Border(top: BorderSide(color: TibaneColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sponsored mode toggle
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$selectedCount selected',
                        style: const TextStyle(
                          color: TibaneColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Reclaim ${formatSol(reclaimableSol)} SOL',
                        style: monoStyle(
                          fontSize: 12,
                          color: TibaneColors.gold,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Sponsored',
                          style: monoStyle(
                            fontSize: 11,
                            color: TibaneColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          height: 24,
                          child: Switch(
                            value: sponsoredMode,
                            onChanged: burning ? null : onToggleSponsored,
                            activeTrackColor: TibaneColors.orange,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            // Tip slider (only in sponsored mode)
            if (sponsoredMode) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    tipPercent.round() == 0
                        ? 'Tip: Minimum'
                        : 'Tip: ${tipPercent.round()}%',
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: tipPercent,
                      min: 0,
                      max: 100,
                      divisions: 100,
                      onChanged: burning ? null : onTipChanged,
                      activeColor: TibaneColors.orange,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // Progress indicator for sponsored burns
            if (burning && sponsoredMode && sponsoredTotal > 0) ...[
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: sponsoredCurrent / sponsoredTotal,
                        backgroundColor: TibaneColors.darker,
                        color: TibaneColors.orange,
                        minHeight: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$sponsoredCurrent/$sponsoredTotal',
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            // Burn button
            GradientButton(
              label: sponsoredMode ? 'Sponsored Burn' : 'Burn',
              icon: Icons.local_fire_department,
              loading: burning,
              expanded: true,
              onPressed: onBurn,
            ),
          ],
        ),
      ),
    );
  }
}
