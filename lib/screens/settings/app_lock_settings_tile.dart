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

class _AppLockSettingsTileState extends State<AppLockSettingsTile>
    with WidgetsBindingObserver {
  late var _availability = _loadAvailability();

  Future<(AppLockBiometricKind, bool)> _loadAvailability() async {
    final lock = widget.controller;
    final passcode = lock.passcodeAvailable();
    return (await lock.availability(), await passcode);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(AppLockSettingsTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _availability = _loadAvailability();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _availability = _loadAvailability());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => FutureBuilder(
      future: _availability,
      builder: (context, snapshot) {
        final lock = widget.controller;
        final l10n = context.l10n;
        final biometric = snapshot.data?.$1;
        final passcode = snapshot.data?.$2;
        final available =
            biometric != null && biometric != AppLockBiometricKind.unavailable;
        final canChange = lock.ready && !lock.busy;
        final failure = switch (lock.failure) {
          AppLockFailure.saving => l10n.appLockSaveFailed,
          AppLockFailure.authentication => l10n.appLockAuthenticationFailed,
          AppLockFailure.unavailable => l10n.appLockMethodUnavailable,
          _ => null,
        };
        return TibaneCard(
          key: const Key('app-lock-setting'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 24),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      l10n.appLockSettingTitle,
                      style: const TextStyle(fontSize: 17.25),
                    ),
                  ),
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: lock.busy || !snapshot.hasData
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              RadioGroup<AppLockMode>(
                groupValue: lock.mode,
                onChanged: (mode) {
                  if (mode == null || !canChange) return;
                  lock.setMode(
                    mode,
                    mode == AppLockMode.off
                        ? l10n.appLockDisableReason
                        : lock.enabled
                        ? l10n.appLockChangeReason
                        : l10n.appLockEnableReason,
                  );
                },
                child: Column(
                  children: [
                    RadioListTile<AppLockMode>(
                      key: const Key('app-lock-mode-off'),
                      value: AppLockMode.off,
                      title: Text(l10n.appLockOff),
                      contentPadding: EdgeInsets.zero,
                      enabled: canChange,
                    ),
                    RadioListTile<AppLockMode>(
                      key: const Key('app-lock-mode-biometric'),
                      value: AppLockMode.biometric,
                      title: Text(
                        biometric == AppLockBiometricKind.face
                            ? l10n.appLockFaceTitle
                            : l10n.appLockBiometrics,
                      ),
                      subtitle: biometric == null
                          ? null
                          : Text(
                              available
                                  ? l10n.appLockSettingSubtitle
                                  : l10n.appLockUnavailable,
                            ),
                      contentPadding: EdgeInsets.zero,
                      enabled: canChange && available,
                    ),
                    if (lock.supportsPasscodeOnly)
                      RadioListTile<AppLockMode>(
                        key: const Key('app-lock-mode-passcode'),
                        value: AppLockMode.passcode,
                        title: Text(l10n.appLockPasscodeOnly),
                        subtitle: passcode == false
                            ? Text(l10n.appLockPasscodeUnavailable)
                            : null,
                        contentPadding: EdgeInsets.zero,
                        enabled: canChange && passcode == true,
                      ),
                  ],
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
        );
      },
    ),
  );
}
