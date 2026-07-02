/// Human-readable label for a libwallet wallet sub-key type. Maps the
/// raw `WalletKey.type` strings (`StoreKey`, `RemoteKey`, `Password`,
/// `Plain`) to the wording shown anywhere the user sees a wallet's
/// shares.
String shareTypeLabel(String type) {
  switch (type) {
    case 'StoreKey':
      return 'Device key';
    case 'RemoteKey':
      return 'Email / SMS 2FA key';
    case 'Password':
      return 'Password';
    case 'Plain':
      return 'Imported key';
    default:
      return type;
  }
}
