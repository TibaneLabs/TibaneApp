import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Region-aware compliance gate driven by the UK FCA's policy on
/// cryptoasset financial promotions (PS23/6, in force 8 Oct 2023).
///
/// Stage 1 policy: when the device is detected as being in the United
/// Kingdom, the app does not surface its own swap or staking entry
/// points — those are regulated activities under FCA rules and we don't
/// hold UK authorisation. UK users keep access to the rest of the wallet
/// (receive, send, browser, settings); they can still reach third-party
/// services via the in-app browser, which is a neutral user-agent.
///
/// Detection uses the device locale country code (Apple region setting /
/// Android system region) as a best-effort proxy for the FCA's "directed
/// at the UK" test. A manual override exists for QA and is exposed in
/// Settings so a user with a mismatched device locale can opt in.
class UkComplianceService extends ChangeNotifier {
  static const _prefsForceUk = 'uk_force_enabled';

  bool _ready = false;
  bool _ukDetected = false;
  bool _ukForced = false;
  String? _detectedCountryCode;

  bool get isReady => _ready;

  /// True when the device locale puts us in the UK, or the manual
  /// override is on. UI surfaces that need to hide swap/staking entry
  /// points key off this.
  bool get isUk => _ukDetected || _ukForced;

  /// Country code resolved from the system locale, for diagnostics in
  /// Settings.
  String? get detectedCountryCode => _detectedCountryCode;

  bool get isForced => _ukForced;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _detectedCountryCode = _resolveCountryCode();
    _ukDetected = _detectedCountryCode == 'GB';
    _ukForced = prefs.getBool(_prefsForceUk) ?? false;
    _ready = true;
    notifyListeners();
  }

  /// Manual override — exposed in Settings so a UK user whose device
  /// region is misconfigured can opt in, and so QA can simulate the
  /// gate.
  Future<void> setForceUk(bool on) async {
    if (_ukForced == on) return;
    _ukForced = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsForceUk, on);
    notifyListeners();
  }

  String? _resolveCountryCode() {
    try {
      final disp = PlatformDispatcher.instance;
      for (final l in disp.locales) {
        final c = l.countryCode;
        if (c != null && c.isNotEmpty) return c.toUpperCase();
      }
      final name = Platform.localeName; // e.g. "en_GB.UTF-8"
      final m = RegExp(r'_([A-Za-z]{2})').firstMatch(name);
      if (m != null) return m.group(1)!.toUpperCase();
    } catch (e) {
      debugPrint('UK locale detection failed: $e');
    }
    return null;
  }
}
