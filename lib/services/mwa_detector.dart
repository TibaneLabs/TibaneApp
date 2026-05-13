import 'dart:io';

import 'package:flutter/services.dart';

const _mwaChannel = MethodChannel('net.tibane.tibaneapp/mwa');

/// Returns `true` when the device has an MWA-compatible wallet app (Seed Vault
/// on the Solana Seeker, or Phantom/Solflare with MWA support). iOS always
/// returns `false`.
Future<bool> hasMwaWallet() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _mwaChannel.invokeMethod<bool>('hasMwaWallet') ?? false;
  } on MissingPluginException {
    return false;
  } catch (_) {
    return false;
  }
}
