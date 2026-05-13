import 'package:flutter/material.dart';

import '../theme/tibane_theme.dart';

/// A card matching the tibane.net card style
class TibaneCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool glowOnHover;

  const TibaneCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.glowOnHover = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TibaneColors.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: TibaneColors.orange.withValues(alpha: 0.08),
        highlightColor: TibaneColors.orange.withValues(alpha: 0.04),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TibaneColors.border),
          ),
          padding: padding ?? const EdgeInsets.all(20),
          child: child,
        ),
      ),
    );
  }
}

/// Feature card with icon, title, description, and optional badge
class FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback? onTap;

  const FeatureCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.badge,
    this.badgeColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TibaneColors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: TibaneColors.orange, size: 24),
              ),
              if (badge != null) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (badgeColor ?? TibaneColors.cyan).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: (badgeColor ?? TibaneColors.cyan).withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    badge!,
                    style: monoStyle(
                      fontSize: 10,
                      color: badgeColor ?? TibaneColors.cyan,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: TibaneColors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: TibaneColors.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stat card for displaying a label and value
class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  final IconData? icon;
  final Color? valueColor;

  /// When non-null, an info icon appears next to the label. Tap to see
  /// this text in a Tooltip (works on touch — Tooltip's tap-trigger).
  final String? tooltip;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.subtitle,
    this.icon,
    this.valueColor,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return TibaneCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: TibaneColors.textDim),
                const SizedBox(width: 6),
              ],
              Text(
                label.toUpperCase(),
                style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 4),
                InfoIcon(message: tooltip!),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: valueColor ?? TibaneColors.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: TibaneColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small info-circle icon that shows [message] in a Tooltip when tapped.
/// Drop next to a label to attach a contextual explanation that doesn't
/// take screen real estate by default.
class InfoIcon extends StatelessWidget {
  final String message;
  final double size;

  const InfoIcon({super.key, required this.message, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      showDuration: const Duration(seconds: 4),
      decoration: BoxDecoration(
        color: TibaneColors.darker,
        border: Border.all(color: TibaneColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        color: TibaneColors.text,
        fontSize: 12,
        height: 1.4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Icon(
        Icons.info_outline,
        size: size,
        color: TibaneColors.textDim,
      ),
    );
  }
}
