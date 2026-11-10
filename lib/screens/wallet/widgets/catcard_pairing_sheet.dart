import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../services/wallet_service.dart';
import '../../../theme/tibane_theme.dart';
import '../../../widgets/cat_logo.dart';

Future<void> showCatCardConnectDialog(
  BuildContext context,
  WalletService wallet,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _CatCardConnectDialog(wallet: wallet),
);

class _CatCardConnectDialog extends StatefulWidget {
  const _CatCardConnectDialog({required this.wallet});

  final WalletService wallet;

  @override
  State<_CatCardConnectDialog> createState() => _CatCardConnectDialogState();
}

class _CatCardConnectDialogState extends State<_CatCardConnectDialog> {
  String? _progress;
  String? _warning;
  String? _error;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connect());
    });
  }

  Future<void> _connect() async {
    final catcard = widget.wallet.catcard;
    final previousStatusListener = catcard.statusListener;
    // This dialog owns only the status presentation for the sidebar request.
    void onStatus(String message) {
      if (!mounted || message == 'Looking for the CatCard…') return;
      setState(() {
        if (message.startsWith('Warning:')) {
          _warning = message;
        } else {
          _progress = message;
        }
      });
    }

    catcard.statusListener = onStatus;
    try {
      final connected = await widget.wallet.connectCatCard();
      if (!mounted) return;
      if (connected) {
        final navigator = Navigator.of(context);
        final route = ModalRoute.of(context);
        if (route?.isCurrent == true) {
          navigator.pop();
        } else if (route?.isActive == true) {
          navigator.removeRoute(route!);
        }
      } else {
        setState(() {
          _error = catcard.error;
          _failed = true;
        });
      }
    } catch (error) {
      debugPrint('[catcard] connection dialog: $error');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (identical(catcard.statusListener, onStatus)) {
        catcard.statusListener = previousStatusListener;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final notFound = _failed && _error == 'No CatCard is plugged in.';
    final title = _failed
        ? (notFound ? l10n.catCardConnectNotFound : l10n.catCardConnectFailed)
        : _progress == null
        ? l10n.catCardConnectLooking
        : l10n.catCardConnectWorking;
    final subtitle = _failed
        ? (notFound ? null : _error)
        : _progress ?? l10n.catCardConnectUsbHint;
    return PopScope(
      canPop: _failed,
      child: AlertDialog(
        backgroundColor: TibaneColors.card,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        constraints: const BoxConstraints.tightFor(width: 340),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        scrollable: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CatLogo(size: 72),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                color: Colors.white,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
        content: subtitle == null && _warning == null
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (subtitle != null)
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: TibaneColors.textMuted,
                        letterSpacing: 0,
                      ),
                    ),
                  if (_warning != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _warning!,
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: TibaneColors.gold,
                      ),
                    ),
                  ],
                ],
              ),
        actionsAlignment: MainAxisAlignment.center,
        actions: _failed
            ? [
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    minimumSize: const Size(112, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(l10n.actionClose),
                ),
              ]
            : null,
      ),
    );
  }
}

/// Show the six-digit pairing code large and ask whether the CatCard shows
/// the same. Resolves true only on "Same code". Not dismissible by tapping
/// outside: a dismissal is a "no", sent explicitly, so the device's prompt
/// goes away too.
Future<bool> showCatCardPairingSheet(BuildContext context, String code) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (ctx) => _PairingSheet(code: code),
  );
  return result ?? false;
}

class _PairingSheet extends StatelessWidget {
  const _PairingSheet({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.usb, color: TibaneColors.text),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.catCardPairTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Center(
              child: Text(
                code,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 4,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.catCardPairBody,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.catCardPairSame),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.catCardPairDifferent),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wire the CatCard backend's UI hooks to the root navigator: the pairing
/// sheet, and progress as snack bars. Called once when [WalletService] is
/// created, so a signing request from any screen can pair on demand.
void installCatCardUi(
  WalletService wallet,
  GlobalKey<NavigatorState> navigatorKey,
) {
  wallet.catcard.codeConfirmer = (code) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    return showCatCardPairingSheet(ctx, code);
  };
  wallet.catcard.statusListener = (message) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  };
}
