import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/tibane_theme.dart';

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
