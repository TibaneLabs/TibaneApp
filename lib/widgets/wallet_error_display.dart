import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tibane_theme.dart';
import '../utils/log.dart';
import '../utils/wallet_error.dart';

/// User-facing display helpers for [WalletError]. These are the single path
/// screens should use to surface an error from a libwallet call — they map the
/// raw error to a friendly message, log the raw detail for the developer, and
/// keep that detail one tap away (copyable) for support. See
/// `ERROR_DISPLAY_AUDIT.md`.
///
/// [WalletError.from] is pure; logging lives here, at the display boundary, so
/// "shown to the user" and "written to the debug log" stay in lock-step (the
/// [Log user errors] rule) without spamming the log on widget rebuilds.

/// Show a friendly error [SnackBar] for [error]. Silent errors (e.g. the user
/// rejecting a web3 request) are logged but not shown. When there's extra raw
/// detail, the SnackBar carries a "Details" action that opens a copyable sheet.
void showWalletError(BuildContext context, Object error) {
  final we = WalletError.from(error);
  logError('[WalletError] ${we.code ?? '-'}', error);
  if (we.silent || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(we.message),
      backgroundColor: TibaneColors.error,
      action: _hasDetail(we)
          ? SnackBarAction(
              label: 'Details',
              textColor: Colors.white,
              onPressed: () {
                if (context.mounted) showWalletErrorDetails(context, we);
              },
            )
          : null,
    ),
  );
}

/// Inline error card for form / loading states. Logs the raw detail once when
/// the error first appears (and again if it changes), never on plain rebuilds.
/// Renders nothing for a [WalletError.silent] error. Pass [onRetry] to offer a
/// retry button.
///
/// A thin wrapper so call sites read `walletErrorCard(e)` alongside the other
/// widget helpers.
Widget walletErrorCard(Object error, {VoidCallback? onRetry}) =>
    WalletErrorCard(error: error, onRetry: onRetry);

class WalletErrorCard extends StatefulWidget {
  final Object error;
  final VoidCallback? onRetry;

  const WalletErrorCard({super.key, required this.error, this.onRetry});

  @override
  State<WalletErrorCard> createState() => _WalletErrorCardState();
}

class _WalletErrorCardState extends State<WalletErrorCard> {
  late WalletError _we = WalletError.from(widget.error);
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _log();
  }

  @override
  void didUpdateWidget(WalletErrorCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.error, widget.error)) {
      _we = WalletError.from(widget.error);
      _showRaw = false;
      _log();
    }
  }

  void _log() => logError('[WalletError] ${_we.code ?? '-'}', widget.error);

  @override
  Widget build(BuildContext context) {
    if (_we.silent) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TibaneColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TibaneColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline,
                  color: TibaneColors.error, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _we.message,
                  style: const TextStyle(color: TibaneColors.text),
                ),
              ),
            ],
          ),
          if (_hasDetail(_we) || widget.onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 30),
              child: Row(
                children: [
                  if (_hasDetail(_we))
                    _LinkButton(
                      label: _showRaw ? 'Hide details' : 'Details',
                      onTap: () => setState(() => _showRaw = !_showRaw),
                    ),
                  if (widget.onRetry != null) ...[
                    if (_hasDetail(_we)) const SizedBox(width: 16),
                    _LinkButton(label: 'Retry', onTap: widget.onRetry!),
                  ],
                ],
              ),
            ),
          if (_showRaw) _RawDetail(raw: _we.raw),
        ],
      ),
    );
  }
}

/// A bottom sheet showing the raw error text with a copy-to-clipboard button.
Future<void> showWalletErrorDetails(BuildContext context, WalletError we) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: TibaneColors.card,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(we.message,
                style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            const Text('Technical details',
                style: TextStyle(color: TibaneColors.textMuted, fontSize: 12)),
            const SizedBox(height: 6),
            _RawDetail(raw: we.raw, copyable: true),
          ],
        ),
      ),
    ),
  );
}

/// True when [we] carries raw detail worth surfacing beyond the friendly
/// message (i.e. the raw text isn't just the message repeated).
bool _hasDetail(WalletError we) {
  final raw = we.raw.trim();
  return raw.isNotEmpty && raw != we.message.trim();
}

/// The raw error text block — selectable, with an optional copy button.
class _RawDetail extends StatelessWidget {
  final String raw;
  final bool copyable;

  const _RawDetail({required this.raw, this.copyable = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TibaneColors.darker,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TibaneColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            raw,
            style: const TextStyle(
                color: TibaneColors.textMuted,
                fontSize: 12,
                fontFamily: 'monospace'),
          ),
          if (copyable)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: raw));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small text button used for the card's Details / Retry affordances.
class _LinkButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _LinkButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: const TextStyle(
            color: TibaneColors.orange,
            fontSize: 13,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}
