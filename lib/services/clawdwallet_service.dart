import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'relay_service.dart' show tibaneApi;

/// Thin REST wrapper for the agent-controlled wallet flow.
///
/// Backed by the existing `Crypto/WalletSign` infrastructure on phplatform:
/// agent wallets are WalletSigns with `Type='agent'` and an attached
/// `Crypto/WalletSign/Policy` of `Kind='agent_skill'`. Lock is the
/// existing `Killed` kill-switch. Activity is the `Crypto_WalletSign_Verify`
/// rows of `Type='txsign'` tied to the wallet.
///
/// All endpoints run under the user's mobile session — same `tibaneApi`
/// bearer used everywhere else in the app. No new auth scheme.
class ClawdWalletService {
  /// Test/screenshot hook: when set, every `ClawdWalletService()` returns
  /// this instance instead of constructing a new one.
  static ClawdWalletService? testInstance;

  factory ClawdWalletService() => testInstance ?? ClawdWalletService.real();

  ClawdWalletService.real();

  /// Create a new agent wallet + skill policy + open keygen Verify session
  /// in one server-side call.
  ///
  /// Returns the raw response map containing:
  ///   - `remote_key`     : `<crws-id>:<crwsv-id>` for the keygen session
  ///   - `wdrone_spot_id` : the wdrone Spot id (also in init_payload.peers)
  ///   - `init_payload`   : `{type, curve, threshold, peers:[{spot_id,
  ///                          moniker, key}], ...}` ready for libwallet to
  ///                          forward to agent + wdrone over walletsign
  ///
  /// Caller should immediately drive libwallet's `Wallet:initiateKeygen`
  /// with the returned material.
  Future<Map<String, dynamic>> create({
    required String name,
    required String agentSpotId,
    required String mobileSpotId,
    required Map<String, dynamic> policy,
  }) async {
    final res = await tibaneApi.authReq(
      'Crypto/WalletSign:newAgent',
      method: 'POST',
      body: {
        'name': name,
        'agent_spot_id': agentSpotId,
        'mobile_spot_id': mobileSpotId,
        'policy': policy,
      },
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// List the current user's agent wallets (WalletSigns with `Type=agent`).
  /// Returns a normalized shape: `{id, name, solana_address, locked, raw}`.
  Future<List<Map<String, dynamic>>> list() async {
    final out = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final res = await tibaneApi.authReq(
        'Crypto/WalletSign',
        method: 'GET',
        body: {'results_per_page': 50, 'page_no': page, 'Type': 'agent'},
      );
      final rows = (res.data as List?) ?? const [];
      for (final row in rows) {
        if (row is Map) {
          out.add(_normalize(Map<String, dynamic>.from(row)));
        }
      }
      final paging = res.paging;
      if (paging != null && page < paging.pageMax) {
        page++;
        continue;
      }
      break;
    }
    return out;
  }

  /// Fetch metadata for a single agent wallet (normalized).
  Future<Map<String, dynamic>> get(String id) async {
    final res = await tibaneApi.authReq('Crypto/WalletSign/$id', method: 'GET');
    return _normalize(Map<String, dynamic>.from(res.data as Map));
  }

  /// Map phplatform's `Crypto_WalletSign` column names onto stable, lowercase
  /// keys the screens read. Keeps the screens decoupled from the schema.
  Map<String, dynamic> _normalize(Map<String, dynamic> row) {
    return {
      'id': row['Crypto_WalletSign__'],
      'name': row['Number'],
      'solana_address': row['Solana_Address'],
      'locked': row['Killed'] == 'Y',
      'created': row['Created'],
      'raw': row,
    };
  }

  /// Flip the kill-switch. While `locked == true`, the policy engine
  /// rejects every `signByPolicy` for this wallet (`Killed='Y'` in DB).
  Future<void> setLocked(String id, bool locked) async {
    await tibaneApi.authReq(
      'Crypto/WalletSign/$id:killSwitch',
      method: 'POST',
      body: {'on': locked},
    );
  }

  /// Paginated activity feed = recent `Crypto_WalletSign_Verify` rows for
  /// this wallet, filtered to TSS sign sessions. Each row carries the
  /// agent's `Object` JSON (parsed_effects + intent) for display.
  ///
  /// Stage 1 polls this every few seconds.
  Future<List<Map<String, dynamic>>> activity(String id, {int page = 1}) async {
    try {
      final res = await tibaneApi.authReq(
        'Crypto/WalletSign_Verify',
        method: 'GET',
        body: {
          'Crypto_WalletSign__': id,
          'Type': 'txsign',
          'page_no': page,
          'results_per_page': 50,
          'sort': 'Created:DESC',
        },
      );
      final rows = (res.data as List?) ?? const [];
      return rows
          .whereType<Map>()
          .map((r) => _normalizeActivity(Map<String, dynamic>.from(r)))
          .toList();
    } catch (e) {
      debugPrint('ClawdWalletService.activity($id) failed: $e');
      rethrow;
    }
  }

  /// Normalize a `Crypto_WalletSign_Verify` row into the shape the activity
  /// screen reads (`{intent, parsed_effects, status, created, raw}`). The
  /// `Object` column carries the JSON the agent shipped via signByPolicy.
  Map<String, dynamic> _normalizeActivity(Map<String, dynamic> row) {
    Map<String, dynamic>? object;
    final raw = row['Object'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) object = Map<String, dynamic>.from(decoded);
      } catch (_) {
        /* leave object null */
      }
    } else if (raw is Map) {
      object = Map<String, dynamic>.from(raw);
    }
    return {
      'id': row['Crypto_WalletSign_Verify__'],
      'status': row['Status'],
      'approved': row['Status'] == 'valid' || row['Status'] == 'done',
      'created': row['Created'],
      'intent': object?['intent'],
      'parsed_effects': object?['parsed_effects'],
      'raw': row,
    };
  }
}
