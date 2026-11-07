import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/tibane_theme.dart';
import 'inapp_import_screen.dart';
import 'wallet_create_options_screen.dart';

class WalletWelcomeScreen extends StatelessWidget {
  const WalletWelcomeScreen({super.key, this.showBackButton = true});

  final bool showBackButton;

  Future<void> _open(BuildContext context, Widget screen) async {
    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => screen));
    if (showBackButton && done == true && context.mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final buttonStyle = FilledButton.styleFrom(
      backgroundColor: TibaneColors.orange,
      foregroundColor: TibaneColors.black,
      minimumSize: const Size.fromHeight(56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      shape: const StadiumBorder(),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: 20.7,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: showBackButton ? AppBar() : null,
      body: SafeArea(
        child: Align(
          alignment: const Alignment(0, -0.18),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/app_icon.png',
                      width: 172.8,
                      height: 172.8,
                      excludeFromSemantics: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.walletSetupWelcome,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: TibaneColors.text,
                      fontSize: 29.9,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('wallet-welcome-create'),
                    onPressed: () =>
                        _open(context, const WalletCreateOptionsScreen()),
                    style: buttonStyle,
                    child: Text(
                      l10n.inappCreateButton,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('wallet-welcome-import'),
                    onPressed: () => _open(context, const InAppImportScreen()),
                    style: buttonStyle,
                    child: Text(
                      l10n.inappImportTitle,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
