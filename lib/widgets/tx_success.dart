import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../theme/tibane_theme.dart';
import '../utils/log.dart';

/// Shared building blocks for the post-transaction "successful" screens (send
/// and swap) and their review sheets: a glowing success mark, tappable receipt
/// cards, the chain explorer link, and the amount / explorer-url helpers. Kept
/// in one place so the two flows stay visually and behaviourally identical.

/// Formats a token amount for display: up to [maxDecimals] fractional digits
/// with insignificant trailing zeros stripped, and the integer part grouped
/// with thousands separators — so `10000` renders as `10,000` and `0.82` stays
/// `0.82`. Pure, for unit-testing the confirm / success amounts.
String formatAmountGrouped(double v, {int maxDecimals = 8}) {
  // Clamp to Dart's toStringAsFixed limit; large-decimal chains (EVM = 18) are
  // still well within range.
  final digits = maxDecimals < 0 ? 0 : (maxDecimals > 20 ? 20 : maxDecimals);
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final dot = s.indexOf('.');
  final intPart = dot == -1 ? s : s.substring(0, dot);
  final fracPart = dot == -1 ? '' : s.substring(dot); // keeps the '.'
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '${neg ? '-' : ''}$buf$fracPart';
}

/// Human name of the block explorer for a chain, for the "View on ..." link
/// (e.g. Solscan / Etherscan). Null when we don't have a branded name — the
/// caller then falls back to a generic "explorer". Pure, for unit tests.
String? explorerNameFor(NetworkType type, String chainId) {
  switch (type) {
    case NetworkType.solana:
      return 'Solscan';
    case NetworkType.evm:
      switch (chainId) {
        case '1':
          return 'Etherscan';
        case '56':
          return 'BscScan';
        case '137':
          return 'Polygonscan';
      }
      return null;
    case NetworkType.bitcoin:
      return null;
    case NetworkType.unknown:
      return null;
  }
}

/// Chain-aware explorer URL for a transaction [hash] on [net] (falls back to
/// Solscan for Solana when the network has no resolved explorer), or null when
/// no explorer / no hash is available. Mirrors the swap-sheet composition.
String? explorerTxUrl(Network? net, String? hash) {
  if (hash == null || net == null) return null;
  final composed = net.transactionUrl(hash);
  if (composed.isNotEmpty) return composed;
  if (net.type == NetworkType.solana) return 'https://solscan.io/tx/$hash';
  return null;
}

/// Copy [value] to the clipboard and show a brief "{label} copied" toast.
/// [label] must already be a localized string supplied by the caller.
void copyWithToast(BuildContext context, String value, String label) {
  Clipboard.setData(ClipboardData(text: value));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(context.l10n.copiedToast(label)),
      duration: const Duration(seconds: 1),
    ),
  );
}

/// Open [url] trying a few launch modes so we don't silently no-op when no
/// default browser is registered. Surfaces a snackbar on failure.
Future<void> openExplorerUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    logError('[txSuccess.openExplorerUrl] invalid URL: $url');
    return;
  }
  Object? lastErr;
  for (final mode in const [
    LaunchMode.externalApplication,
    LaunchMode.inAppBrowserView,
    LaunchMode.platformDefault,
  ]) {
    try {
      if (await launchUrl(uri, mode: mode)) return;
    } catch (e) {
      lastErr = e;
    }
  }
  logError('[txSuccess.openExplorerUrl] could not open $url: $lastErr');
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Could not open $url')));
}

/// Middle-ellipsis for a long tx signature ("5mR8x9Lp…x2Kp"); returns the
/// value unchanged when short, and null for null. Pure.
String? shortenTxHash(String? s) {
  if (s == null) return null;
  if (s.length <= 16) return s;
  return '${s.substring(0, 8)}…${s.substring(s.length - 6)}';
}

/// The glowing green check mark shown at the top of a success screen.
Widget txSuccessMark({double size = 96}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: TibaneColors.cyan.withValues(alpha: 0.10),
      border: Border.all(color: TibaneColors.cyan, width: 2.5),
      boxShadow: [
        BoxShadow(
          color: TibaneColors.cyan.withValues(alpha: 0.45),
          blurRadius: 32,
          spreadRadius: 2,
        ),
      ],
    ),
    child: Icon(
      Icons.check_rounded,
      color: TibaneColors.cyan,
      size: size * 0.54,
    ),
  );
}

/// A tappable receipt row (icon + label + value, optional [trailing]). [onTap]
/// is usually a copy action; null renders a non-interactive card.
Widget txReceiptCard({
  required IconData icon,
  required String label,
  required String value,
  VoidCallback? onTap,
  Widget? trailing,
}) {
  return Material(
    color: TibaneColors.darker,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TibaneColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: TibaneColors.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: TibaneColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(fontSize: 13, color: TibaneColors.text),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    ),
  );
}

/// The orange "View ... on ..." explorer link with an external-link glyph.
Widget txExplorerLink({required VoidCallback onTap, required String label}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: TibaneColors.orange,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.open_in_new, size: 13, color: TibaneColors.orange),
        ],
      ),
    ),
  );
}

/// The full-width orange "Back to home" button that pops the current tab's
/// navigator stack back to its root.
/// When no [label] is provided the localized [AppLocalizations.backToHome] string
/// is used. Callers that DO pass a label (already localized) keep their override.
Widget txBackToHomeButton(BuildContext context, {String? label}) {
  final resolvedLabel = label ?? context.l10n.backToHome;
  return SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
      style: FilledButton.styleFrom(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(
        resolvedLabel,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
  );
}
