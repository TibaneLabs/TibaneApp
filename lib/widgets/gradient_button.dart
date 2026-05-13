import 'package:flutter/material.dart';

import '../theme/tibane_theme.dart';

/// Primary gradient button matching tibane.net .btn-primary style
class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expanded;

  const GradientButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        gradient: enabled ? TibaneColors.brandGradient : null,
        color: enabled ? null : TibaneColors.textDim.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: TibaneColors.orange.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(8),
          splashColor: Colors.white.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TibaneColors.black,
                    ),
                  ),
                  const SizedBox(width: 10),
                ] else if (icon != null) ...[
                  Icon(icon, size: 18, color: TibaneColors.black),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: enabled ? TibaneColors.black : TibaneColors.textDim,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Secondary button with card background
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expanded;

  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      onPressed: loading ? null : onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: TibaneColors.card,
        side: const BorderSide(color: TibaneColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, size: 16),
            const SizedBox(width: 8),
          ],
          Text(label),
        ],
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}
