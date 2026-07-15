import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show AgentIdentity;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/relay_service.dart' show tibaneApi;
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';
import '../../widgets/tibane_card.dart';
import '../../utils/amount.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Form to provision a new ClawdWallet (agent-controlled MPC wallet).
///
/// Flow:
///   1. Owner fills name + agent spot id + policy fields.
///   2. POST `Crypto/ClawdWallet:create` opens the policy record and a
///      walletsign keygen session, returning `{id, remote_key, peers,
///      wdrone_spot_id}`.
///   3. Mobile (this device, Share 3) joins the 3-party EdDSA keygen by
///      calling libwallet's `Wallet:joinKeygen` with the returned material.
///      The agent (Share 1) and wdrone (Share 2) join in parallel.
///   4. On success the Solana address is shown to the owner with a "fund
///      this address" prompt.
///
/// Uses libwallet's `Wallet:initiateKeygen` (mobile is the keygen leader per
/// the integration contract). The action sends `walletsign/<sid>/init` to
/// the agent and wdrone peers, then runs mobile's own EdDSA keygen LocalParty.
///
/// Two entry paths:
///   - Manual: open the screen from the Agents tab, type the agent_spot_id.
///   - Deep-link: arrive from the pairing handler with [verifiedIdentity]
///     pre-filled. The agent_spot_id is locked and visibly marked verified.
class CreateAgentWalletScreen extends StatefulWidget {
  /// When non-null, the agent has been verified by `ClawdWallet:pair`. Fill
  /// the form with its values and lock the trustworthy fields so the user
  /// can't accidentally edit them.
  final AgentIdentity? verifiedIdentity;

  const CreateAgentWalletScreen({super.key, this.verifiedIdentity});

  @override
  State<CreateAgentWalletScreen> createState() =>
      _CreateAgentWalletScreenState();
}

enum _Stage { form, keygen, done, error }

class _CreateAgentWalletScreenState extends State<CreateAgentWalletScreen> {
  final _nameCtrl = TextEditingController();
  final _agentSpotCtrl = TextEditingController();
  final _perTxCtrl = TextEditingController(text: '50');
  final _dailyCtrl = TextEditingController(text: '500');
  final _allowlistCtrl = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  _Stage _stage = _Stage.form;
  String? _error;

  // Populated once libwallet `Wallet:joinKeygen` is wired up.
  // Read by `_buildDone()`.
  String? _solanaAddress;
  String? _walletId;

  /// True when the agent identity came from the pairing handler. Drives the
  /// read-only state of the spot id field and the "verified" badge.
  bool get _isVerified => widget.verifiedIdentity != null;

  @override
  void initState() {
    super.initState();
    final id = widget.verifiedIdentity;
    if (id != null) {
      _agentSpotCtrl.text = id.agentSpotId;
      if (id.suggestedName.isNotEmpty) {
        _nameCtrl.text = id.suggestedName;
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _agentSpotCtrl.dispose();
    _perTxCtrl.dispose();
    _dailyCtrl.dispose();
    _allowlistCtrl.dispose();
    super.dispose();
  }

  List<String> _parseAllowlist() {
    final raw = _allowlistCtrl.text.trim();
    if (raw.isEmpty) return const [];
    return raw
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    context.unfocus();

    final policy = <String, dynamic>{
      'per_tx_max_usd': parseAmount(_perTxCtrl.text) ?? 0,
      'daily_max_usd': parseAmount(_dailyCtrl.text) ?? 0,
      'recipient_allowlist': _parseAllowlist(),
      'recipient_denylist': const <String>[],
    };

    setState(() {
      _stage = _Stage.keygen;
      _error = null;
    });

    try {
      final client = await context
          .read<WalletService>()
          .libwallet
          .ensureClient();

      // libwallet 0.4.25 collapses the previous flow (fetch spot id → POST
      // newAgent → drive initiateKeygen) into a single high-level call. We
      // hand it our atonline session so it can authenticate the one POST it
      // makes; libwallet doesn't manage bearer tokens.
      final result = await client.wallets.createAgentWallet(
        api: tibaneApi,
        name: _nameCtrl.text.trim(),
        agentSpotId: _agentSpotCtrl.text.trim(),
        policy: policy,
      );

      if (!mounted) return;
      setState(() {
        _walletId = result.walletId;
        _solanaAddress = result.solanaAddress;
        _stage = _Stage.done;
      });
    } catch (e) {
      logError('[CreateAgentWallet._submit] keygen error: $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _error = WalletError.from(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(context.l10n.clawdCreateTitle)),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.form => _buildForm(),
          _Stage.keygen => _buildKeygen(),
          _Stage.done => _buildDone(),
          _Stage.error => _buildError(),
        },
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: TibaneColors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.precision_manufacturing,
                        color: TibaneColors.orange,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.l10n.clawdCreateSchemeTitle,
                        style: context.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  context.l10n.clawdCreateSchemeBody,
                  style: const TextStyle(color: TibaneColors.textMuted, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionLabel(context.l10n.labelWallet),
          const SizedBox(height: 10),
          TextFormField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: context.l10n.labelWalletName,
              hintText: 'e.g. ops-agent',
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? context.l10n.clawdCreateRequired : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _agentSpotCtrl,
            readOnly: _isVerified,
            decoration: InputDecoration(
              labelText: context.l10n.clawdCreateAgentSpotIdLabel,
              hintText: _isVerified
                  ? null
                  : 'Paste from `clawdwallet init` or open a pair link',
              suffixIcon: _isVerified
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified,
                            color: TibaneColors.cyan,
                            size: 18,
                          ),
                          SizedBox(width: 4),
                          Text(
                            context.l10n.clawdCreateVerified,
                            style: const TextStyle(
                              color: TibaneColors.cyan,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
              helperText: _isVerified
                  ? (widget.verifiedIdentity!.agentVersion.isNotEmpty
                        ? 'Agent version: ${widget.verifiedIdentity!.agentVersion}'
                        : null)
                  : null,
            ),
            style: monoStyle(fontSize: 13),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? context.l10n.clawdCreateRequired : null,
            inputFormatters: _isVerified
                ? null
                : [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[A-Za-z0-9\-_]'),
                    ),
                  ],
          ),
          const SizedBox(height: 24),
          _SectionLabel(context.l10n.clawdCreateSectionPolicy),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _perTxCtrl,
                  decoration: InputDecoration(
                    labelText: context.l10n.clawdCreatePerTxMax,
                    suffixText: 'USD',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _validateNumber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _dailyCtrl,
                  decoration: InputDecoration(
                    labelText: context.l10n.clawdCreateDailyMax,
                    suffixText: 'USD',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _validateNumber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _allowlistCtrl,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: context.l10n.clawdCreateAllowlistLabel,
              hintText: context.l10n.clawdCreateAllowlistHint,
              alignLabelWithHint: true,
            ),
            style: monoStyle(fontSize: 12),
          ),
          const SizedBox(height: 28),
          GradientButton(
            label: context.l10n.clawdCreateProvisionButton,
            icon: Icons.add_circle_outline,
            expanded: true,
            onPressed: _submit,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.clawdCreateProvisionHint,
            style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  String? _validateNumber(String? v) {
    if (v == null || v.trim().isEmpty) return context.l10n.clawdCreateRequired;
    final n = parseAmount(v);
    if (n == null || n < 0) return context.l10n.clawdCreateInvalid;
    return null;
  }

  Widget _buildKeygen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                color: TibaneColors.orange,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              context.l10n.clawdCreateKeygenTitle,
              style: context.textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.clawdCreateKeygenBody,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TibaneColors.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: TibaneColors.cyan,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.l10n.clawdCreateDoneTitle,
                      style: context.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.settingsSolanaAddressLabel,
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  _solanaAddress ?? '',
                  style: monoStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: _solanaAddress ?? ''),
                        );
                        context.showSnackBar(
                          SnackBar(
                            content: Text(context.l10n.addressCopied),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 14),
                      label: Text(context.l10n.actionCopyAddress),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TibaneCard(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TibaneColors.gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.payments_outlined,
                    color: TibaneColors.gold,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    context.l10n.clawdCreateFundHint,
                    style: const TextStyle(color: TibaneColors.text, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          GradientButton(
            label: context.l10n.actionDone,
            expanded: true,
            onPressed: () => Navigator.of(context).pop(_walletId),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TibaneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: TibaneColors.error,
                      size: 24,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      context.l10n.clawdCreateKeygenFailed,
                      style: context.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _error ?? context.l10n.clawdCreateUnknownError,
                  style: const TextStyle(
                    color: TibaneColors.textMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          GradientButton(
            label: context.l10n.clawdCreateBackToForm,
            expanded: true,
            onPressed: () => setState(() {
              _stage = _Stage.form;
              _error = null;
            }),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: monoStyle(fontSize: 11, color: TibaneColors.textDim),
    );
  }
}
