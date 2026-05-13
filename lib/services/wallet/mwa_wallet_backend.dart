import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../solana_common.dart';
import 'wallet_backend.dart';

const _mwaChannel = MethodChannel('net.tibane.tibaneapp/mwa');
const _identityUri = 'https://tibane.net';
const _identityIcon = 'favicon.ico';
const _identityName = 'Tibane';

/// Backend that drives an external Solana Mobile Wallet Adapter (Seed Vault,
/// Phantom, Solflare, ...). Android-only; iOS users should pick a different
/// backend.
class MwaWalletBackend extends ChangeNotifier implements WalletBackend {
  @override
  String get id => 'mwa';

  String? _publicKey;
  String? _authToken;
  String? _walletName;
  bool _connecting = false;
  String? _error;

  @override
  String? get publicKey => _publicKey;
  @override
  String? get walletName => _walletName;
  @override
  bool get isConnected => _publicKey != null;
  @override
  bool get isConnecting => _connecting;
  @override
  String? get error => _error;

  @override
  Future<void> tryRestore() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString('wallet_public_key');
    if (savedKey != null) {
      _publicKey = savedKey;
      _walletName = prefs.getString('wallet_name') ?? 'Wallet';
      _authToken = prefs.getString('wallet_auth_token');
      notifyListeners();
    }
  }

  Future<bool> connect() async {
    if (_connecting) return false;
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _mwaChannel.invokeMethod<Map>('authorize', {
        'identityUri': _identityUri,
        'iconUri': _identityIcon,
        'identityName': _identityName,
        'cluster': 'mainnet-beta',
      });

      if (result == null) {
        _error = 'Authorization was rejected';
        return false;
      }

      final pubKeyBytes = result['publicKey'];
      if (pubKeyBytes is Uint8List) {
        _publicKey = base58Encode(pubKeyBytes);
      }
      _authToken = result['authToken'] as String?;
      _walletName = (result['accountLabel'] as String?) ?? 'Wallet';

      if (_publicKey == null) return false;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wallet_public_key', _publicKey!);
      await prefs.setString('wallet_name', _walletName!);
      if (_authToken != null) {
        await prefs.setString('wallet_auth_token', _authToken!);
      }
      debugPrint('MWA connected as $_walletName ($_publicKey)');
      return true;
    } on PlatformException catch (e) {
      _error = e.code == 'NO_WALLET'
          ? 'No Solana wallet app installed. Use the in-app wallet instead.'
          : 'Failed to connect: ${e.message}';
      debugPrint('MWA connect error [${e.code}]: ${e.message}');
      return false;
    } catch (e) {
      _error = 'Failed to connect: $e';
      debugPrint('MWA connect error: $e');
      return false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  @override
  Future<void> disconnect() async {
    if (_authToken != null) {
      try {
        await _mwaChannel.invokeMethod('deauthorize', {
          'identityUri': _identityUri,
          'identityName': _identityName,
          'authToken': _authToken,
        });
      } catch (_) {
        // Best-effort.
      }
    }
    _publicKey = null;
    _authToken = null;
    _walletName = null;
    _error = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wallet_public_key');
    await prefs.remove('wallet_name');
    await prefs.remove('wallet_auth_token');

    notifyListeners();
  }

  Future<void> _persistToken(String token) async {
    _authToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wallet_auth_token', token);
  }

  @override
  Future<Uint8List?> signMessage(Uint8List message) async {
    if (!_ensureConnected()) return null;
    try {
      final result = await _mwaChannel.invokeMethod<Map>('signMessages', {
        'identityUri': _identityUri,
        'identityName': _identityName,
        'authToken': _authToken,
        'messages': [message],
      });
      if (result == null) return null;
      final newToken = result['authToken'] as String?;
      if (newToken != null) await _persistToken(newToken);
      final sigs = result['signatures'] as List?;
      if (sigs != null && sigs.isNotEmpty) {
        final sig = sigs.first;
        if (sig is Uint8List) return sig;
      }
      return null;
    } on PlatformException catch (e) {
      _error = 'Message signing failed: ${e.message}';
      debugPrint('MWA signMessage error: ${e.message}');
      notifyListeners();
      return null;
    } catch (e) {
      _error = 'Message signing failed: $e';
      debugPrint('MWA signMessage error: $e');
      notifyListeners();
      return null;
    }
  }

  @override
  Future<List<Uint8List?>> signTransactions(List<Uint8List> transactions) async {
    if (!_ensureConnected()) return List.filled(transactions.length, null);
    try {
      final result = await _mwaChannel.invokeMethod<Map>('signTransactions', {
        'identityUri': _identityUri,
        'identityName': _identityName,
        'authToken': _authToken,
        'transactions': transactions,
      });
      if (result == null) return List.filled(transactions.length, null);
      final newToken = result['authToken'] as String?;
      if (newToken != null) await _persistToken(newToken);
      final signed = result['signedTransactions'] as List?;
      if (signed == null) return List.filled(transactions.length, null);
      return signed.map((tx) => tx is Uint8List ? tx : null).toList();
    } on PlatformException catch (e) {
      _error = 'Signing failed: ${e.message}';
      debugPrint('MWA signTransactions error: ${e.message}');
      notifyListeners();
      return List.filled(transactions.length, null);
    } catch (e) {
      _error = 'Signing failed: $e';
      debugPrint('MWA signTransactions error: $e');
      notifyListeners();
      return List.filled(transactions.length, null);
    }
  }

  @override
  Future<List<String?>> signAndSendTransactions(List<Uint8List> transactions) async {
    if (!_ensureConnected()) return List.filled(transactions.length, null);
    try {
      final result = await _mwaChannel.invokeMethod<Map>('signAndSendTransactions', {
        'identityUri': _identityUri,
        'identityName': _identityName,
        'authToken': _authToken,
        'transactions': transactions,
      });
      if (result == null) return List.filled(transactions.length, null);
      final newToken = result['authToken'] as String?;
      if (newToken != null) await _persistToken(newToken);
      final sigs = result['signatures'] as List?;
      if (sigs == null) return List.filled(transactions.length, null);
      return sigs.map((sig) {
        if (sig is Uint8List) return base58Encode(sig);
        return null;
      }).toList();
    } on PlatformException catch (e) {
      _error = 'Transaction failed: ${e.message}';
      debugPrint('MWA signAndSend error: ${e.message}');
      notifyListeners();
      return List.filled(transactions.length, null);
    } catch (e) {
      _error = 'Transaction failed: $e';
      debugPrint('MWA signAndSend error: $e');
      notifyListeners();
      return List.filled(transactions.length, null);
    }
  }

  bool _ensureConnected() {
    if (isConnected && _authToken != null) return true;
    _error = 'Wallet not connected';
    notifyListeners();
    return false;
  }

  @override
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
