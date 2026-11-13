import 'package:libwallet/libwallet.dart' show Wallet;

/// The kinds of hardware signer libwallet holds as wallets (0.5.9+). A
/// hardware wallet is watch-only on the phone: its accounts carry public keys
/// read from the device, and every signature comes from the device itself.
enum HardwareKind {
  /// CatCard over USB (the device's CCID smart-card reader).
  catcard,

  /// Ledger over USB-OTG (Android) or Bluetooth.
  ledger,

  /// An air-gapped signer (Keystone, Coldcard, Passport, …) over QR codes.
  airgap,
}

/// The hardware kind of a libwallet wallet `Protocol`, or null for a software
/// (MPC / mnemonic / imported-key) wallet.
HardwareKind? hardwareKindOfProtocol(String? protocol) => switch (protocol) {
  'catcard' => HardwareKind.catcard,
  'ledger' => HardwareKind.ledger,
  'airgap' => HardwareKind.airgap,
  _ => null,
};

HardwareKind? hardwareKindOf(Wallet? wallet) =>
    hardwareKindOfProtocol(wallet?.protocol);

/// Whether [wallet] is a hardware signer (no keys on the phone).
bool isHardwareWallet(Wallet? wallet) => hardwareKindOf(wallet) != null;

/// The account types the app can show for a hardware wallet. libwallet also
/// imports Tron keys, which this app has no screens for, so they stay hidden.
const List<String> kHardwareAccountTypes = ['solana', 'ethereum', 'bitcoin'];

/// The device can display an account's address for the user to compare.
bool hardwareCanShowAddress(HardwareKind kind) =>
    kind == HardwareKind.catcard || kind == HardwareKind.ledger;

/// The Ledger app that holds keys for an account type.
String? ledgerAppForAccountType(String type) => switch (type) {
  'ethereum' => 'Ethereum',
  'bitcoin' => 'Bitcoin',
  'solana' => 'Solana',
  _ => null,
};
