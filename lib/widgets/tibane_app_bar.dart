import 'package:flutter/material.dart';

import '../theme/tibane_theme.dart';
import 'cat_logo.dart';
import 'network_chip.dart';
import 'wallet_button.dart';

/// The shared, Tibane-branded top bar (CatLogo + title + NetworkChip +
/// WalletButton). Used as the [Scaffold.appBar] of each bottom-nav tab root, so
/// the branding shows on tab roots while pushed detail screens supply their own
/// AppBar (with a back button). See NAVIGATION_MIGRATION.md.
class TibaneAppBar extends StatelessWidget implements PreferredSizeWidget {
  const TibaneAppBar({super.key});

  static const double _height = 56;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: TibaneColors.black,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: _height,
      title: Row(
        children: [
          const CatLogo(size: 28),
          const SizedBox(width: 10),
          Text(
            'Tibane',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 8),
          const NetworkChip(),
        ],
      ),
      actions: const [WalletButton(), SizedBox(width: 12)],
    );
  }
}
