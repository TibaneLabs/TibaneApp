/// Human-readable label for a libwallet wallet sub-key type. Maps the
/// raw `WalletKey.type` strings (`StoreKey`, `RemoteKey`, `Password`,
/// `Plain`) to the wording shown anywhere the user sees a wallet's
/// shares.
String shareTypeLabel(String type) {
  switch (type) {
    case 'StoreKey':
      return 'Device share';
    case 'RemoteKey':
      return 'Email / SMS second factor';
    case 'Password':
      return 'Password share';
    case 'Plain':
      return 'Imported share';
    default:
      return type;
  }
}
