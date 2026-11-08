import 'package:biometric_storage/biometric_storage.dart' show AuthException;
import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show Wallet;

import '../../l10n/l10n.dart';
import '../../services/wallet/libwallet_backend.dart';
import '../../services/wallet/normal_wallet_biometrics.dart';
import '../../services/wallet/wallet_export_format.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/wallet_error.dart';
import '../../widgets/tibane_card.dart';
import '../wallet/widgets/wallet_password_dialog.dart';

class NormalWalletBiometricsTile extends StatefulWidget {
  const NormalWalletBiometricsTile({
    super.key,
    required this.backend,
    required this.wallet,
  });
  final LibwalletBackend backend;
  final Wallet wallet;

  @override
  State<NormalWalletBiometricsTile> createState() =>
      _NormalWalletBiometricsTileState();
}

class _NormalWalletBiometricsTileState
    extends State<NormalWalletBiometricsTile> {
  late Future<({NormalBiometricKind kind, bool enabled})> _status;
  bool _busy = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _status = _load();
  }

  @override
  void didUpdateWidget(NormalWalletBiometricsTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallet.id != widget.wallet.id ||
        oldWidget.wallet.gen != widget.wallet.gen ||
        oldWidget.wallet.keys.single.id != widget.wallet.keys.single.id) {
      _status = _load();
    }
  }

  Future<({NormalBiometricKind kind, bool enabled})> _load() async {
    final auth = widget.backend.normalWalletBiometrics;
    final targets = await widget.backend.normalBiometricWallets();
    final enabled = await Future.wait(targets.map(auth.isEnabled));
    return (
      kind: await auth.availability(),
      enabled: enabled.isNotEmpty && enabled.every((value) => value),
    );
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    final backend = widget.backend;
    final selected = widget.wallet;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      if (value) {
        final consent = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true,
            title: Text(l10n.normalBiometricsEnableTitle),
            content: Text(
              isNormalMnemonicWallet(selected)
                  ? l10n.normalBiometricsSeedConsent
                  : l10n.normalBiometricsPrivateConsent,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.actionConfirm),
              ),
            ],
          ),
        );
        if (!mounted || consent != true) return;
        String? password;
        if (isNormalMnemonicWallet(selected)) {
          password = await showWalletPasswordDialog(context);
          if (!mounted || password == null || password.isEmpty) return;
        }
        if (backend.walletId != selected.id) return;
        setState(() => _working = true);
        await backend.enableNormalWalletBiometrics(
          password: password,
          prompt: NormalBiometricPrompt(
            l10n.normalBiometricsAuthorize,
            l10n.actionCancel,
          ),
        );
      } else {
        if (backend.walletId != selected.id) return;
        setState(() => _working = true);
        await backend.disableNormalWalletBiometrics(
          l10n.normalBiometricsDisable,
        );
      }
    } on AuthException {
      // A dismissed system prompt leaves the setting unchanged.
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is NormalBiometricUnavailable
                  ? l10n.normalBiometricsUnavailable
                  : walletErrorMessageForContext(context, error),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = false;
          _status = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _status,
    builder: (context, snapshot) {
      final status = snapshot.data;
      final l10n = context.l10n;
      final face = status?.kind == NormalBiometricKind.face;
      final enabled = status?.enabled ?? false;
      final available =
          status != null &&
          (status.kind != NormalBiometricKind.unavailable || enabled);
      return TibaneCard(
        key: const Key('normal-wallet-biometrics'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(face ? Icons.face_outlined : Icons.fingerprint, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    face
                        ? l10n.normalBiometricsFaceTitle
                        : l10n.normalBiometricsTitle,
                    style: const TextStyle(fontSize: 17.25),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.wallet.name}\n${available ? l10n.normalBiometricsSubtitle : l10n.normalBiometricsUnavailable}',
                    style: monoStyle(
                      fontSize: 12.65,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              height: 48,
              child: _working
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Switch.adaptive(
                      key: const Key('normal-biometrics-switch'),
                      value: enabled,
                      onChanged: available && !_busy ? _toggle : null,
                    ),
            ),
          ],
        ),
      );
    },
  );
}
