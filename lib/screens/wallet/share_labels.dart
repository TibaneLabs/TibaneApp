import '../../l10n/l10n.dart';

/// Human-readable label for a libwallet wallet sub-key type. Maps the
/// raw `WalletKey.type` strings (`StoreKey`, `RemoteKey`, `Password`,
/// `Plain`) to the wording shown anywhere the user sees a wallet's
/// shares.
String shareTypeLabel(String type, AppLocalizations l10n) {
  switch (type) {
    case 'StoreKey':
      return l10n.shareLabelsDeviceKey;
    case 'RemoteKey':
      return l10n.shareLabelsRemoteKey;
    case 'Password':
      return l10n.labelPassword;
    case 'Plain':
      return l10n.shareLabelsImportedKey;
    default:
      return type;
  }
}
