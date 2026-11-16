import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// User-facing help for the current wallet and account flows.
class HelpFaqScreen extends StatelessWidget {
  const HelpFaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final faqGroups = [
      _FaqGroup(
        title: l10n.helpFaqBackupsGroup,
        icon: Icons.backup_outlined,
        items: [
          _Faq(l10n.helpFaqBackupHowQ, l10n.helpFaqBackupHowA),
          _Faq(l10n.helpFaqPrivateKeyQ, l10n.helpFaqPrivateKeyA),
          _Faq(l10n.helpFaqRestoreHowQ, l10n.helpFaqRestoreHowA),
          _Faq(l10n.helpFaqRestoredCantSendQ, l10n.helpFaqRestoredCantSendA),
          _Faq(l10n.helpFaqLostMpcContactQ, l10n.helpFaqLostMpcContactA),
        ],
      ),
      _FaqGroup(
        title: l10n.helpFaqMovingPhoneGroup,
        icon: Icons.phonelink_setup_outlined,
        items: [
          _Faq(l10n.helpFaqMoveWalletQ, l10n.helpFaqMoveWalletA),
          _Faq(l10n.helpFaqTwoPhonesQ, l10n.helpFaqTwoPhonesA),
          _Faq(l10n.helpFaqShareErrorQ, l10n.helpFaqShareErrorA),
        ],
      ),
      _FaqGroup(
        title: l10n.helpFaqPassword2faGroup,
        icon: Icons.password_outlined,
        items: [
          _Faq(l10n.helpFaqChangePasswordQ, l10n.helpFaqChangePasswordA),
          _Faq(l10n.helpFaqForgotPasswordQ, l10n.helpFaqForgotPasswordA),
          _Faq(l10n.helpFaqWhat2faQ, l10n.helpFaqWhat2faA),
        ],
      ),
      _FaqGroup(
        title: l10n.helpFaqSigningSecurityGroup,
        icon: Icons.verified_user_outlined,
        items: [
          _Faq(l10n.helpFaqWhySignEveryTimeQ, l10n.helpFaqWhySignEveryTimeA),
          _Faq(l10n.helpFaqBiometricsQ, l10n.helpFaqBiometricsA),
          _Faq(l10n.helpFaqDappsQ, l10n.helpFaqDappsA),
        ],
      ),
      _FaqGroup(
        title: l10n.helpFaqToolsGroup,
        icon: Icons.handyman_outlined,
        items: [
          _Faq(l10n.helpFaqReclaimQ, l10n.helpFaqReclaimA),
          _Faq(l10n.helpFaqBulkQ, l10n.helpFaqBulkA),
        ],
      ),
    ];

    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.helpFaqTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              l10n.helpFaqIntro,
              style: const TextStyle(
                color: TibaneColors.textMuted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            for (final group in faqGroups) ...[
              _GroupHeader(icon: group.icon, title: group.title),
              const SizedBox(height: 8),
              TibaneCard(
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Column(
                    children: [
                      for (var i = 0; i < group.items.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 1,
                            thickness: 1,
                            color: TibaneColors.border,
                          ),
                        _FaqTile(item: group.items[i]),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

class _Faq {
  final String q;
  final String a;
  const _Faq(this.q, this.a);
}

class _FaqGroup {
  final String title;
  final IconData icon;
  final List<_Faq> items;
  const _FaqGroup({
    required this.title,
    required this.icon,
    required this.items,
  });
}

class _GroupHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _GroupHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: TibaneColors.orange, size: 18 * 1.3),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: TibaneColors.text,
              fontSize: 15 * 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqTile extends StatelessWidget {
  final _Faq item;
  const _FaqTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      // Strip ExpansionTile's default expanded top/bottom borders — the card
      // already frames the group.
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedAlignment: Alignment.topLeft,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      iconColor: TibaneColors.orange,
      collapsedIconColor: TibaneColors.textMuted,
      title: Text(
        item.q,
        style: const TextStyle(
          color: TibaneColors.text,
          fontSize: 14 * 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
      children: [
        Text(
          item.a,
          style: const TextStyle(
            color: TibaneColors.textMuted,
            fontSize: 13 * 1.15,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
