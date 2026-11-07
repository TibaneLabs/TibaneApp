import 'package:flutter/material.dart';

import '../../../theme/tibane_theme.dart';
import '../../../widgets/tibane_card.dart';

class WalletSetupMethodCard extends StatelessWidget {
  const WalletSetupMethodCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.centered = false,
    this.unavailableLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool centered;
  final String? unavailableLabel;

  @override
  Widget build(BuildContext context) {
    final emblem = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: TibaneColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: TibaneColors.orange, size: 24),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        if (centered) ...[emblem, const SizedBox(height: 12)],
        Text(
          title,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: TibaneColors.text,
            fontSize: centered ? 20 : 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: TibaneColors.textMuted,
            fontSize: centered ? 15 : 14,
            height: 1.4,
            letterSpacing: 0,
          ),
        ),
        if (unavailableLabel != null) ...[
          const SizedBox(height: 8),
          Text(
            unavailableLabel!,
            style: const TextStyle(
              color: TibaneColors.orange,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ],
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: TibaneCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: centered
            ? Stack(
                alignment: Alignment.centerRight,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: SizedBox(width: double.infinity, child: content),
                  ),
                  if (onTap != null)
                    const Icon(
                      Icons.chevron_right,
                      color: TibaneColors.textDim,
                      size: 20,
                    ),
                ],
              )
            : Row(
                children: [
                  emblem,
                  const SizedBox(width: 16),
                  Expanded(child: content),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right,
                    color: TibaneColors.textDim,
                    size: 20,
                  ),
                ],
              ),
      ),
    );
  }
}
