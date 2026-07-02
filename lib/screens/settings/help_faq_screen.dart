import 'package:flutter/material.dart';

import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// Help & FAQ (Settings → Help). Plain, self-contained answers about backups,
/// moving a wallet to a new phone, passwords/2FA, and why signing prompts each
/// time — matching how the MPC wallet actually behaves (single device-key slot,
/// backups exclude the device key, device transfer vs restore, etc.).
///
/// English-only inline literals per the app convention (D15).
class HelpFaqScreen extends StatelessWidget {
  const HelpFaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Help & FAQ')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Common questions about backing up, moving to a new phone, and '
              'how your keys work.',
              style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 20),
            for (final group in _faqGroups) ...[
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
  const _FaqGroup(this.title, this.icon, this.items);
}

const List<_FaqGroup> _faqGroups = [
  _FaqGroup('Backups', Icons.backup_outlined, [
    _Faq(
      'How do I back up my wallet?',
      'Open your wallet, go to its details, and tap Export to save a backup '
          'file. Keep it somewhere safe and private. When your phone\'s system '
          'backup is on (iCloud on iPhone, Google on Android), the app also '
          'keeps an automatic copy there.\n\n'
          'Anyone who has your backup file AND your password can access your '
          'funds — treat both like cash.',
    ),
    _Faq(
      'How do I restore from a backup?',
      'When adding a wallet, choose Import wallet → Tibane backup, open your '
          'backup file (or paste the JSON), and enter the wallet\'s password. '
          'When it finishes, tap "Set up now" to create this phone\'s signing '
          'key with a 2FA code.',
    ),
    _Faq(
      "I restored from a backup file but I can't send — why?",
      'A backup file never contains a signing key (it\'s device-only for '
          'security), so a restore alone can\'t sign. Finish with "Set up this '
          'device": a quick 2FA verification creates a signing key on this '
          'phone. Until then, sending is blocked — if you try to send you\'ll '
          'see a "Set up" shortcut that takes you there.\n\n'
          '(Moving with "Transfer to new device" instead brings the signing key '
          'with it, so that path needs no extra setup.)',
    ),
  ]),
  _FaqGroup('Moving to a new phone', Icons.phonelink_setup_outlined, [
    _Faq(
      'How do I move my wallet to a new phone?',
      'If you still have the old phone, use Transfer to new device — it\'s the '
          'smoothest way. On the old phone open the wallet and tap "Transfer to '
          'new device" to show a QR code; on the new phone choose "Receive from '
          'another device" and scan it, then enter the password. The signing key '
          'travels securely between the phones, so no 2FA code is needed.\n\n'
          'If you only have a backup file, restore it on the new phone and then '
          '"Set up this device".',
    ),
    _Faq(
      'Can I use the same wallet on two phones at the same time?',
      'A wallet\'s signing key lives on one phone at a time. When you '
          '"Set up this device" on a new phone, that phone becomes the wallet\'s '
          'signing device and the previous phone will need to be set up again '
          'before it can sign. Plan to sign from one phone.',
    ),
    _Faq(
      'My backup file gives an error about a "share" or "party key".',
      'That backup is out of date. Every time a wallet is set up on a device '
          'its keys are refreshed, which makes older backup files stale. Export '
          'a FRESH backup from the phone that currently works, then import that '
          'one. Don\'t use "Repair 2FA key" with an old file — it can push a '
          'stale key and break the phone that\'s working.',
    ),
  ]),
  _FaqGroup('Password & 2FA', Icons.password_outlined, [
    _Faq(
      'How do I change my password?',
      'Go to Settings → Security & Privacy → Change password. You\'ll confirm '
          'the change with a 2FA code.',
    ),
    _Faq(
      'I forgot my password.',
      'Open the wallet\'s details (or Security & Privacy) and choose '
          '"Forgot password? Reset via 2FA". Verify with a 2FA code and set a '
          'new password.',
    ),
    _Faq(
      'What is the 2FA key, and what does "Repair 2FA key" do?',
      'Your 2FA key is a recovery key tied to your email or phone number. It\'s '
          'used to recover or repair a wallet — not for everyday signing. If '
          'setting up a restored wallet gets stuck ("participant stopped '
          'responding"), your 2FA key may be out of sync; "Repair 2FA key" '
          're-syncs it from your backup so setup can finish. Only repair from '
          'the phone whose wallet currently works.',
    ),
  ]),
  _FaqGroup('Signing & security', Icons.verified_user_outlined, [
    _Faq(
      'Why does every send ask for my password and fingerprint/face?',
      'Your wallet is protected by three keys, and any two are needed to '
          'approve a transaction: this phone\'s key (unlocked with your '
          'fingerprint or face) plus your password. There is no "unlock once" — '
          'every transaction is approved on its own, so a lost or stolen phone '
          'can\'t sign without your password.',
    ),
  ]),
];

class _GroupHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _GroupHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: TibaneColors.orange, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: TibaneColors.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
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
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      children: [
        Text(
          item.a,
          style: const TextStyle(
            color: TibaneColors.textMuted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
