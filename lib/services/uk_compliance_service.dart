import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Region-aware compliance gate driven by the UK FCA's policy on
/// cryptoasset financial promotions (PS23/6, in force 8 Oct 2023).
///
/// Stage 1 policy: when the user is detected as being in the United
/// Kingdom, the app does not surface its own swap or staking entry
/// points — those are regulated activities under FCA rules and we don't
/// hold UK authorisation. UK users keep access to the rest of the wallet
/// (receive, send, browser, settings); they can still reach third-party
/// services via the in-app browser, which is a neutral user-agent.
///
/// Detection prefers the App Store account country (via a narrow
/// StoreKit channel on iOS), and falls back to the device locale when
/// the storefront isn't readable (signed-out, Android, etc.). A manual
/// override is exposed in Settings.
class UkComplianceService extends ChangeNotifier {
  static const _prefsForceUk = 'uk_force_enabled';
  static const _storefrontChannel =
      MethodChannel('net.tibane.tibaneapp/storefront');

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
    _detectedCountryCode = await _resolveCountryCode();
    _ukDetected = _isUkCode(_detectedCountryCode);
    _ukForced = prefs.getBool(_prefsForceUk) ?? false;
    _ready = true;
    notifyListeners();
  }

  /// Both ISO 3166-1 alpha-3 ("GBR", from StoreKit) and alpha-2 ("GB",
  /// from device locale) count as the United Kingdom for our purposes.
  bool _isUkCode(String? c) => c == 'GBR' || c == 'GB';

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

  /// Prefer the App Store / Play storefront country; fall back to the
  /// device locale when the native channel returns null (signed-out,
  /// Android without the StoreKit equivalent wired, web/desktop, …).
  Future<String?> _resolveCountryCode() async {
    if (Platform.isIOS) {
      try {
        final code = await _storefrontChannel
            .invokeMethod<String>('countryCode');
        if (code != null && code.isNotEmpty) return code.toUpperCase();
      } catch (e) {
        debugPrint('storefront countryCode lookup failed: $e');
      }
    }
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
