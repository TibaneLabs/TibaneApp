import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/app_lock_controller.dart';
import '../theme/tibane_theme.dart';
import 'cat_logo.dart';

/// Wrap the root Navigator, not an individual tab or route.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});
  final AppLockController controller;
  final Widget child;
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  int? _lastAutoAttempt;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.handleLifecycle(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
      );
      _changed();
    });
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _lastAutoAttempt = null;
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      widget.controller.handleLifecycle(state);

  void _changed() {
    if (!mounted) return;
    if (widget.controller.blocksContent) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final lock = widget.controller;
      if (!lock.needsUnlock ||
          !lock.foreground ||
          lock.busy ||
          _lastAutoAttempt == lock.lockSession) {
        return;
      }
      _lastAutoAttempt = lock.lockSession;
      unawaited(lock.unlock(context.l10n.appLockAuthenticate));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final lock = widget.controller;
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: lock.blocksContent,
            child: ExcludeSemantics(
              excluding: lock.blocksContent,
              child: Offstage(
                offstage: lock.blocksContent,
                child: widget.child,
              ),
            ),
          ),
          if (lock.blocksContent)
            Positioned.fill(child: _LockSurface(controller: lock)),
        ],
      );
    },
  );
}

class _LockSurface extends StatelessWidget {
  const _LockSurface({required this.controller});
  final AppLockController controller;
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loadingError = controller.failure == AppLockFailure.loading;
    return ScaffoldMessenger(
      child: Scaffold(
        key: const Key('app-lock-surface'),
        backgroundColor: TibaneColors.black,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CatLogo(size: 72),
                                if (!controller.privacyOnly) ...[
                                  const SizedBox(height: 28),
                                  if (!controller.ready && !loadingError)
                                    const CircularProgressIndicator()
                                  else ...[
                                    Text(
                                      l10n.appLockLockedTitle,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      loadingError
                                          ? l10n.appLockLoadFailed
                                          : controller.mode ==
                                                AppLockMode.passcode
                                          ? l10n.appLockPasscodeLockedBody
                                          : l10n.appLockLockedBody,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        color: TibaneColors.textMuted,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    if (controller.failure ==
                                        AppLockFailure.authentication) ...[
                                      Text(
                                        l10n.appLockAuthenticationFailed,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: TibaneColors.error,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                    ],
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!controller.privacyOnly && (controller.ready || loadingError))
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        key: const Key('app-lock-unlock'),
                        onPressed: controller.busy
                            ? null
                            : () => loadingError
                                  ? controller.load()
                                  : controller.unlock(l10n.appLockAuthenticate),
                        icon: controller.busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_open_outlined),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            loadingError
                                ? l10n.actionRetry
                                : l10n.appLockUnlock,
                          ),
                        ),
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
