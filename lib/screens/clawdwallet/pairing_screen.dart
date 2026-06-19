import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';

import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/gradient_button.dart';
import '../../widgets/tibane_card.dart';
import 'create_agent_wallet_screen.dart';
import '../../utils/log.dart';

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
      final mapped = _messageFor(e);
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
        _errorTitle = 'Pairing failed';
        _errorBody = 'An unexpected error occurred: $e';
      });
    }
  }

  /// Map a typed pairing exception to (title, body) for display. Keep both
  /// strings short — they render in a card with a "Try again" button below.
  (String, String) _messageFor(PairingException e) {
    return switch (e) {
      PairingURLMalformedException _ => (
        'Pairing URL is malformed',
        'This link is missing the agent or token, or uses the wrong scheme. Ask the agent to print a fresh URL.',
      ),
      PairingAgentUnreachableException _ => (
        'Could not reach the agent',
        'The agent host did not answer within the timeout. Check your network connection, then open a fresh pairing URL from the agent and try again.',
      ),
      PairingTokenInvalidException _ => (
        'Pairing code not recognised',
        'The agent does not recognise this token — the agent may have restarted, or the URL is for a different agent. Run `clawdwallet pair` again to get a fresh URL.',
      ),
      PairingTokenExpiredException _ => (
        'The pairing code expired',
        'Pairing codes are valid for 5 minutes. Run `clawdwallet pair` again to get a fresh URL.',
      ),
      PairingTokenConsumedException _ => (
        'This pairing code has already been used',
        'Each pairing URL is single-use. Run `clawdwallet pair` again to get a fresh URL.',
      ),
      PairingIdentityMismatchException _ => (
        'Pairing identity mismatch',
        'The agent that responded does not match the one named in the URL. Treat this as suspicious and do not proceed. Run `clawdwallet pair` again from a trusted terminal.',
      ),
      PairingBadRequestException _ => (
        'Agent rejected the pair request',
        'The agent and the app may be running incompatible versions. Update the agent (and the app, if newer than what you installed) and try again.',
      ),
      _ => ('Pairing failed', e.message),
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
        appBar: AppBar(title: const Text('Pair agent')),
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
              'Verifying agent',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            const Text(
              "Contacting the agent over Spot to confirm the pairing URL. "
              "This usually takes a second.",
              textAlign: TextAlign.center,
              style: TextStyle(color: TibaneColors.textMuted, height: 1.5),
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
                        _errorTitle ?? 'Pairing failed',
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
            label: 'Close',
            expanded: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
