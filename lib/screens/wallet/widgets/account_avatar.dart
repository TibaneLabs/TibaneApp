import 'package:flutter/material.dart';

import '../../../services/wallet/account_avatar_assets.dart';
import '../../../theme/tibane_theme.dart';

class AccountAvatar extends StatelessWidget {
  final String? asset;
  final double size;
  final bool active;
  final IconData fallbackIcon;

  const AccountAvatar({
    super.key,
    required this.asset,
    this.size = 44,
    this.active = false,
    this.fallbackIcon = Icons.account_circle_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final imageAsset = asset;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipOval(
            child: imageAsset == null
                ? ColoredBox(
                    color: TibaneColors.darker,
                    child: Center(
                      child: Icon(
                        fallbackIcon,
                        color: active
                            ? TibaneColors.orange
                            : TibaneColors.textMuted,
                        size: size * 0.55,
                      ),
                    ),
                  )
                : Image.asset(
                    imageAsset,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? TibaneColors.orange.withValues(alpha: 0.72)
                    : TibaneColors.border.withValues(alpha: 0.40),
                width: active ? 2 : 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AccountAvatarSelector extends StatelessWidget {
  final String label;
  final String selectedAsset;
  final ValueChanged<String> onSelected;

  const AccountAvatarSelector({
    super.key,
    required this.label,
    required this.selectedAsset,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TibaneColors.darker,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openPicker(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: TibaneColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: monoStyle(fontSize: 12, color: TibaneColors.textMuted),
                ),
              ),
              AccountAvatar(asset: selectedAsset, active: true, size: 46),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: TibaneColors.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: TibaneColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TibaneColors.textDim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(label, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 14),
              AccountAvatarPicker(
                selectedAsset: selectedAsset,
                onSelected: (asset) {
                  onSelected(asset);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountAvatarPicker extends StatelessWidget {
  final String selectedAsset;
  final ValueChanged<String> onSelected;

  const AccountAvatarPicker({
    super.key,
    required this.selectedAsset,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final asset in kAccountAvatarAssets)
          _AvatarChoice(
            asset: asset,
            selected: asset == selectedAsset,
            onTap: () => onSelected(asset),
          ),
      ],
    );
  }
}

class _AvatarChoice extends StatelessWidget {
  final String asset;
  final bool selected;
  final VoidCallback onTap;

  const _AvatarChoice({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? TibaneColors.orange : Colors.transparent,
            width: 2,
          ),
        ),
        child: AccountAvatar(asset: asset, size: 42, active: selected),
      ),
    );
  }
}
