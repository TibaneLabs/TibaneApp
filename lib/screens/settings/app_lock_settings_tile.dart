import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/app_lock_controller.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

class AppLockSettingsTile extends StatefulWidget {
  const AppLockSettingsTile({super.key, required this.controller});
  final AppLockController controller;
  @override
  State<AppLockSettingsTile> createState() => _AppLockSettingsTileState();
}

class _AppLockSettingsTileState extends State<AppLockSettingsTile> {
  late final _availability = widget.controller.availability();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => FutureBuilder(
      future: _availability,
      builder: (context, snapshot) {
        final lock = widget.controller;
        final l10n = context.l10n;
        final face = snapshot.data == AppLockBiometricKind.face;
        final available =
            snapshot.hasData &&
            (snapshot.data != AppLockBiometricKind.unavailable || lock.enabled);
        final failure = switch (lock.failure) {
          AppLockFailure.saving => l10n.appLockSaveFailed,
          AppLockFailure.authentication => l10n.appLockAuthenticationFailed,
          AppLockFailure.unavailable => l10n.appLockUnavailable,
          _ => null,
        };
        return TibaneCard(
          key: const Key('app-lock-setting'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(face ? Icons.face_outlined : Icons.lock_outline, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      face ? l10n.appLockFaceTitle : l10n.appLockSettingTitle,
                      style: const TextStyle(fontSize: 17.25),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      available
                          ? l10n.appLockSettingSubtitle
                          : l10n.appLockUnavailable,
                      style: monoStyle(
                        fontSize: 12.65,
                        color: TibaneColors.textMuted,
                      ),
                    ),
                    if (failure != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          failure,
                          style: const TextStyle(color: TibaneColors.error),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 52,
                height: 48,
                child: lock.busy
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Switch.adaptive(
                        key: const Key('app-lock-switch'),
                        value: lock.enabled,
                        onChanged: available && lock.ready
                            ? (value) => lock.setEnabled(
                                value,
                                value
                                    ? l10n.appLockEnableReason
                                    : l10n.appLockDisableReason,
                              )
                            : null,
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
