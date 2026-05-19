import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/uk_compliance_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';
import '../about_screen.dart';
import '../settings_screen.dart' show SettingsTile;

/// Sub-screen reached from Settings → "General". Catch-all for app-level
/// options that aren't tied to a specific wallet/security flow.
class GeneralScreen extends StatelessWidget {
  const GeneralScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('General')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _UkComplianceTile(),
              const SizedBox(height: 6),
              SettingsTile(
                icon: Icons.info_outline,
                title: 'About Tibane',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: TibaneColors.black,
                      appBar: AppBar(title: const Text('About')),
                      body: const SafeArea(child: AboutScreen()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UkComplianceTile extends StatelessWidget {
  const _UkComplianceTile();

  @override
  Widget build(BuildContext context) {
    final uk = context.watch<UkComplianceService>();
    final country = uk.detectedCountryCode ?? 'unknown';
    final detected = country == 'GB' || country == 'GBR';
    final subtitle = detected
        ? 'Detected as United Kingdom. Swap and staking are hidden.'
        : (uk.isForced
            ? 'UK mode is forced ON. Swap and staking are hidden.'
            : 'Detected region: $country. Swap and staking are available.');
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                uk.isUk ? Icons.shield_outlined : Icons.public,
                color: uk.isUk ? TibaneColors.warning : TibaneColors.textMuted,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'UK compliance',
                      style: TextStyle(
                        color: TibaneColors.text,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: monoStyle(
                        fontSize: 11,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (!detected)
                Switch(
                  value: uk.isForced,
                  activeThumbColor: TibaneColors.orange,
                  onChanged: (v) => uk.setForceUk(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
