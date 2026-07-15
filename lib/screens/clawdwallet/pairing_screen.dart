import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';
import '../../widgets/tibane_card.dart';
import 'create_agent_wallet_screen.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Handles an incoming `clawd://pair?agent=...&token=...` URL.
///
/// Runs libwallet's `ClawdWallet:pair` handshake while showing a spinner, then
/// either pushes the [CreateAgentWalletScreen] with the verified
/// [AgentIdentity] pre-filled or surfaces a typed error with a retry path.
class PairingScreen extends StatefulWidget {
  final String url;

  const PairingScreen({super.key, required this.url});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

enum _Stage { pairing, error }

class _PairingScreenState extends State<PairingScreen> {
  _Stage _stage = _Stage.pairing;
  String? _errorTitle;
  String? _errorBody;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPair());
  }

  Future<void> _runPair() async {
    final wallet = context.read<WalletService>();
    try {
      final client = await wallet.libwallet.ensureClient();
      final identity = await client.clawdWallet.pair(widget.url);
      if (!mounted) return;
      // Replace this screen with the create form so back-button doesn't
      // re-enter pairing.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CreateAgentWalletScreen(verifiedIdentity: identity),
        ),
      );
    } on PairingException catch (e) {
      logError('[Pairing._runPair] pairing error: $e');
      if (!mounted) return;
      final l10n = context.l10n;
      final mapped = _messageFor(l10n, e);
      setState(() {
        _stage = _Stage.error;
        _errorTitle = mapped.$1;
        _errorBody = mapped.$2;
      });
    } catch (e) {
      logError('[Pairing._runPair] unexpected error: $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorTitle = context.l10n.clawdPairingFailed;
        _errorBody = WalletError.from(e).message;
      });
    }
  }

  /// Map a typed pairing exception to (title, body) for display. Keep both
  /// strings short — they render in a card with a "Try again" button below.
  (String, String) _messageFor(AppLocalizations l10n, PairingException e) {
    return switch (e) {
      PairingURLMalformedException _ => (
        l10n.clawdPairingErrUrlMalformedTitle,
        l10n.clawdPairingErrUrlMalformedBody,
      ),
      PairingAgentUnreachableException _ => (
        l10n.clawdPairingErrUnreachableTitle,
        l10n.clawdPairingErrUnreachableBody,
      ),
      PairingTokenInvalidException _ => (
        l10n.clawdPairingErrTokenInvalidTitle,
        l10n.clawdPairingErrTokenInvalidBody,
      ),
      PairingTokenExpiredException _ => (
        l10n.clawdPairingErrTokenExpiredTitle,
        l10n.clawdPairingErrTokenExpiredBody,
      ),
      PairingTokenConsumedException _ => (
        l10n.clawdPairingErrTokenConsumedTitle,
        l10n.clawdPairingErrTokenConsumedBody,
      ),
      PairingIdentityMismatchException _ => (
        l10n.clawdPairingErrIdentityMismatchTitle,
        l10n.clawdPairingErrIdentityMismatchBody,
      ),
      PairingBadRequestException _ => (
        l10n.clawdPairingErrBadRequestTitle,
        l10n.clawdPairingErrBadRequestBody,
      ),
      _ => (l10n.clawdPairingFailed, e.message),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block back-gesture while the handshake is in flight; let it through
      // on the error screen so the user can leave.
      canPop: _stage == _Stage.error,
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(title: Text(context.l10n.clawdPairingTitle)),
        body: SafeArea(
          child: switch (_stage) {
            _Stage.pairing => _buildPairing(),
            _Stage.error => _buildError(),
          },
        ),
      ),
    );
  }

  Widget _buildPairing() {
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
              context.l10n.clawdPairingVerifyingTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.clawdPairingVerifyingBody,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TibaneColors.textMuted, height: 1.5),
            ),
          ],
        ),
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
                    Expanded(
                      child: Text(
                        _errorTitle ?? context.l10n.clawdPairingFailed,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _errorBody ?? '',
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
            label: context.l10n.actionClose,
            expanded: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
