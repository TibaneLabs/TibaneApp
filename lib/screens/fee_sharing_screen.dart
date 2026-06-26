import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants/solana_constants.dart';
import '../services/pumpfees_instructions.dart';
import '../services/rpc_service.dart';
import '../services/solana_common.dart';
import '../services/spl_instructions.dart';
import '../services/wallet_service.dart';
import '../theme/tibane_theme.dart';
import '../widgets/gradient_button.dart';
import '../widgets/tibane_card.dart';
import 'wallet/widgets/authorize_and_sign.dart';
import '../utils/log.dart';

class FeeSharingScreen extends StatefulWidget {
  final String mint;
  final String? tokenName;

  const FeeSharingScreen({super.key, required this.mint, this.tokenName});

  @override
  State<FeeSharingScreen> createState() => _FeeSharingScreenState();
}

class _FeeSharingScreenState extends State<FeeSharingScreen> {
  final _rpc = RpcService();
  SharingConfig? _config;
  BigInt _creatorVaultBalance = BigInt.zero;
  BigInt _pumpswapVaultBalance = BigInt.zero;
  bool _loading = false;
  bool _executing = false;
  String? _error;

  // Update shares form
  final _newShareholderController = TextEditingController();
  final _newBpsController = TextEditingController();
  List<FeeShareHolder> _editedShareholders = [];

  // Transfer authority form
  final _newAdminController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _newShareholderController.dispose();
    _newBpsController.dispose();
    _newAdminController.dispose();
    _rpc.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await _rpc.getSharingConfig(widget.mint);
      if (data != null) {
        final config = SharingConfig.deserialize(data);
        setState(() {
          _config = config;
          _editedShareholders = config?.shareholders.toList() ?? [];
          _loading = false;
        });
        _fetchVaultBalances();
      } else {
        setState(() {
          _config = null;
          _loading = false;
        });
      }
    } catch (e) {
      logError('[FeeSharing._loadConfig] load error: $e');
      setState(() {
        _error = 'Failed to load config: $e';
        _loading = false;
      });
    }
  }

  Future<void> _fetchVaultBalances() async {
    try {
      final sharingConfig = deriveSharingConfigPda(widget.mint);
      final pumpVault = derivePumpCreatorVaultPda(sharingConfig);
      final coinCreatorAuth = deriveCoinCreatorVaultAuthorityPda(sharingConfig);
      // Pump creator vault: system account lamports
      try {
        final balance = await _rpc.getBalance(pumpVault);
        setState(() => _creatorVaultBalance = balance);
      } catch (_) {}
      // PumpSwap vault: WSOL ATA token amount at offset 64
      try {
        final wsolAta = deriveATA(coinCreatorAuth, wsolMint, splTokenProgramId);
        final info = await _rpc.getAccountInfo(wsolAta);
        if (info != null && info.length >= 72) {
          final bd = ByteData.sublistView(info);
          final lo = bd.getUint32(64, Endian.little);
          final hi = bd.getUint32(68, Endian.little);
          setState(
            () => _pumpswapVaultBalance =
                BigInt.from(lo) + (BigInt.from(hi) << 32),
          );
        }
      } catch (_) {}
    } catch (_) {}
  }

  bool get _isAdmin {
    final wallet = context.read<WalletService>();
    return _config != null &&
        wallet.publicKey == _config!.admin &&
        !_config!.adminRevoked;
  }

  Future<void> _createConfig() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected) return;
    if (!mounted) return;

    setState(() => _executing = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final ix = createFeeSharingConfigIx(
        payer: wallet.publicKey!,
        mint: widget.mint,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      if (!mounted) return;
      final sigs = await authorizeAndSignAndSend(
        context,
        [Uint8List.fromList(tx)],
      );
      if (!mounted) return;
      if (sigs == null) return; // cancelled / not authorized
      final sig = sigs.first;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Config created: ${sig.substring(0, 8)}...')),
        );
      }
    } catch (e) {
      logError('[FeeSharing._createConfig] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _executing = false);
      _loadConfig();
    }
  }

  Future<void> _distributeFees() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected || _config == null) return;
    if (!mounted) return;

    setState(() => _executing = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final instructions = <SolanaInstruction>[];

      // First transfer from PumpSwap AMM to pump creator vault
      instructions.add(transferCreatorFeesToPumpIx(mint: widget.mint));

      // Then distribute from pump creator vault to shareholders
      instructions.add(
        distributeCreatorFeesIx(
          mint: widget.mint,
          shareholders: _config!.shareholders,
        ),
      );

      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: instructions,
      );
      if (!mounted) return;
      final sigs = await authorizeAndSignAndSend(
        context,
        [Uint8List.fromList(tx)],
      );
      if (!mounted) return;
      if (sigs == null) return; // cancelled / not authorized
      final sig = sigs.first;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fees distributed: ${sig.substring(0, 8)}...'),
          ),
        );
      }
    } catch (e) {
      logError('[FeeSharing._distributeFees] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _executing = false);
      _loadConfig();
    }
  }

  Future<void> _updateShares() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected || _config == null || !_isAdmin) return;
    if (!mounted) return;

    setState(() => _executing = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final ix = updateFeeSharesIx(
        admin: wallet.publicKey!,
        mint: widget.mint,
        newShareholders: _editedShareholders,
        currentShareholders: _config!.shareholders,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      if (!mounted) return;
      final sigs = await authorizeAndSignAndSend(
        context,
        [Uint8List.fromList(tx)],
      );
      if (!mounted) return;
      if (sigs == null) return; // cancelled / not authorized
      final sig = sigs.first;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Shares updated: ${sig.substring(0, 8)}...')),
        );
      }
    } catch (e) {
      logError('[FeeSharing._updateShares] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _executing = false);
      _loadConfig();
    }
  }

  Future<void> _transferAuthority() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected || !_isAdmin) return;

    final newAdmin = _newAdminController.text.trim();
    if (newAdmin.length < 32) return;

    if (!mounted) return;

    setState(() => _executing = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final ix = transferFeeSharingAuthorityIx(
        currentAdmin: wallet.publicKey!,
        newAdmin: newAdmin,
        mint: widget.mint,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      if (!mounted) return;
      final sigs = await authorizeAndSignAndSend(
        context,
        [Uint8List.fromList(tx)],
      );
      if (!mounted) return;
      if (sigs == null) return; // cancelled / not authorized
      final sig = sigs.first;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Authority transferred: ${sig.substring(0, 8)}...'),
          ),
        );
        _newAdminController.clear();
      }
    } catch (e) {
      logError('[FeeSharing._transferAuthority] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _executing = false);
      _loadConfig();
    }
  }

  Future<void> _revokeAuthority() async {
    final wallet = context.read<WalletService>();
    if (!wallet.isConnected || !_isAdmin) return;

    // Confirm revocation
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Revoke Authority?'),
        content: const Text(
          'This action is irreversible. The fee sharing configuration will become immutable.',
          style: TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Revoke',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;
    if (!mounted) return;

    setState(() => _executing = true);
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final ix = revokeFeeSharingAuthorityIx(
        admin: wallet.publicKey!,
        mint: widget.mint,
      );
      final tx = buildTransaction(
        recentBlockhash: blockhash,
        feePayer: wallet.publicKey!,
        instructions: [ix],
      );
      if (!mounted) return;
      final sigs = await authorizeAndSignAndSend(
        context,
        [Uint8List.fromList(tx)],
      );
      if (!mounted) return;
      if (sigs == null) return; // cancelled / not authorized
      final sig = sigs.first;
      if (sig != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Authority revoked: ${sig.substring(0, 8)}...'),
          ),
        );
      }
    } catch (e) {
      logError('[FeeSharing._revokeAuthority] error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _executing = false);
      _loadConfig();
    }
  }

  void _addShareholder() {
    final addr = _newShareholderController.text.trim();
    final bps = int.tryParse(_newBpsController.text.trim()) ?? 0;
    if (addr.length < 32 || bps <= 0 || bps > 2000) return;

    setState(() {
      _editedShareholders.add(FeeShareHolder(address: addr, bps: bps));
      _newShareholderController.clear();
      _newBpsController.clear();
    });
  }

  void _removeShareholder(int index) {
    setState(() => _editedShareholders.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        backgroundColor: TibaneColors.black,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          widget.tokenName != null ? '${widget.tokenName} Fees' : 'Fee Sharing',
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadConfig,
            icon: const Icon(Icons.refresh, size: 20),
            color: TibaneColors.textMuted,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: TibaneColors.orange),
            )
          : _error != null
          ? Center(
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
                    _error!,
                    style: const TextStyle(color: TibaneColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _loadConfig,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              color: TibaneColors.orange,
              onRefresh: _loadConfig,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                physics: const AlwaysScrollableScrollPhysics(),
                child: _config == null
                    ? _buildNoConfig(wallet)
                    : _buildConfig(wallet),
              ),
            ),
    );
  }

  Widget _buildNoConfig(WalletService wallet) {
    return Column(
      children: [
        TibaneCard(
          child: Column(
            children: [
              const Icon(Icons.settings, size: 40, color: TibaneColors.textDim),
              const SizedBox(height: 12),
              Text(
                'No fee sharing config exists for this token',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: TibaneColors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Anyone can create a fee sharing config for a pump.fun token.',
                style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (wallet.isConnected)
          GradientButton(
            label: 'Create Config',
            icon: Icons.add,
            loading: _executing,
            expanded: true,
            onPressed: _createConfig,
          )
        else
          const Text(
            'Connect wallet to create config',
            style: TextStyle(color: TibaneColors.textMuted),
          ),
      ],
    );
  }

  Widget _buildConfig(WalletService wallet) {
    final config = _config!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Config info
        Text(
          'CONFIG',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        TibaneCard(
          child: Column(
            children: [
              _InfoRow(label: 'Mint', value: shortenAddress(config.mint)),
              _InfoRow(
                label: 'Admin',
                value: config.adminRevoked
                    ? 'Revoked'
                    : shortenAddress(config.admin),
              ),
              _InfoRow(
                label: 'Status',
                value: config.status == 0
                    ? 'Active'
                    : 'Status ${config.status}',
              ),
              _InfoRow(label: 'Version', value: '${config.version}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Vault balances
        if (_creatorVaultBalance > BigInt.zero ||
            _pumpswapVaultBalance > BigInt.zero)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              children: [
                if (_creatorVaultBalance > BigInt.zero)
                  Expanded(
                    child: StatCard(
                      label: 'Creator Vault',
                      value: '${formatSol(_creatorVaultBalance)} SOL',
                      valueColor: TibaneColors.gold,
                      icon: Icons.account_balance,
                    ),
                  ),
                if (_creatorVaultBalance > BigInt.zero &&
                    _pumpswapVaultBalance > BigInt.zero)
                  const SizedBox(width: 8),
                if (_pumpswapVaultBalance > BigInt.zero)
                  Expanded(
                    child: StatCard(
                      label: 'PumpSwap Vault',
                      value: '${formatSol(_pumpswapVaultBalance)} SOL',
                      valueColor: TibaneColors.gold,
                      icon: Icons.swap_horiz,
                    ),
                  ),
              ],
            ),
          ),

        // Shareholders
        Text(
          'SHAREHOLDERS',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        if (config.shareholders.isEmpty)
          TibaneCard(
            child: Text(
              'No shareholders configured',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: TibaneColors.textMuted),
            ),
          )
        else
          TibaneCard(
            child: Column(
              children: [
                for (var i = 0; i < config.shareholders.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: TibaneColors.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text(
                            '#${i + 1}',
                            style: monoStyle(
                              fontSize: 11,
                              color: TibaneColors.textDim,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(
                                  text: config.shareholders[i].address,
                                ),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Address copied')),
                              );
                            },
                            child: Text(
                              shortenAddress(
                                config.shareholders[i].address,
                                chars: 6,
                              ),
                              style: monoStyle(
                                fontSize: 12,
                                color: TibaneColors.textMuted,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          '${config.shareholders[i].percent.toStringAsFixed(1)}%',
                          style: monoStyle(
                            fontSize: 12,
                            color: TibaneColors.gold,
                          ),
                        ),
                        Text(
                          ' (${config.shareholders[i].bps} bps)',
                          style: monoStyle(
                            fontSize: 10,
                            color: TibaneColors.textDim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 20),

        // Permissionless actions (anyone can do these)
        Text(
          'ACTIONS',
          style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
        ),
        const SizedBox(height: 12),
        if (wallet.isConnected && config.shareholders.isNotEmpty)
          GradientButton(
            label: 'Distribute Fees',
            icon: Icons.payments,
            loading: _executing,
            expanded: true,
            onPressed: _distributeFees,
          ),
        const SizedBox(height: 20),

        // Admin actions
        if (_isAdmin) ...[
          Text(
            'ADMIN',
            style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
          ),
          const SizedBox(height: 12),

          // Edit shareholders
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Update Shares',
                  style: TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                // Current edited list
                for (var i = 0; i < _editedShareholders.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            shortenAddress(
                              _editedShareholders[i].address,
                              chars: 6,
                            ),
                            style: monoStyle(
                              fontSize: 11,
                              color: TibaneColors.textMuted,
                            ),
                          ),
                        ),
                        Text(
                          '${_editedShareholders[i].bps} bps',
                          style: monoStyle(
                            fontSize: 11,
                            color: TibaneColors.gold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _removeShareholder(i),
                          child: const Icon(
                            Icons.close,
                            size: 16,
                            color: TibaneColors.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                // Add new shareholder
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _newShareholderController,
                        decoration: const InputDecoration(
                          hintText: 'Address',
                          isDense: true,
                        ),
                        style: monoStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _newBpsController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: 'BPS',
                          isDense: true,
                        ),
                        style: monoStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _addShareholder,
                      icon: const Icon(
                        Icons.add_circle,
                        color: TibaneColors.orange,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  label: 'Save Shares',
                  icon: Icons.save,
                  expanded: true,
                  onPressed: _executing ? null : _updateShares,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Transfer authority
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transfer Authority',
                  style: TextStyle(
                    color: TibaneColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _newAdminController,
                  decoration: const InputDecoration(
                    hintText: 'New admin address',
                  ),
                  style: monoStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  label: 'Transfer',
                  icon: Icons.swap_horiz,
                  expanded: true,
                  onPressed: _executing ? null : _transferAuthority,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Revoke authority
          SecondaryButton(
            label: 'Revoke Authority (Irreversible)',
            icon: Icons.block,
            expanded: true,
            onPressed: _executing ? null : _revokeAuthority,
          ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
          ),
          Text(value, style: monoStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
