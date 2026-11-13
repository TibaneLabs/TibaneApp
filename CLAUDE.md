# Tibane App

Flutter app for Solana Seeker phone, providing Tibane Labs tools from tibane.net.

## Architecture

- **Theme**: `lib/theme/tibane_theme.dart` - Dark theme matching tibane.net (orange/gold accents, DM Sans font)
- **Services**: `lib/services/` - WalletService (MWA), RpcService (Helius RPC)
- **Hardware wallets** (libwallet ≥ 0.5.9): CatCard, Ledger and air-gapped signers are libwallet wallets (`Protocol` `catcard` / `ledger` / `airgap`, watch-only accounts, mixed curve `""`), so they run under `WalletKind.inapp` with `UnifiedAccount.hardware` set. Signing goes through the normal `*WithKeys` paths with an empty key list (`collectSigningKeys` skips the sign sheet and calls `HardwareWalletService.prepareToSign`); libwallet has the device sign.
  - `lib/services/hardware/hardware_wallet_service.dart` - relays (`catcard.ccidBridge`, `ledger.bridge`), CatCard pairing, `airgap:sign` events; UI hooks wired by `installHardwareWalletUi` (`screens/wallet/widgets/hardware_status.dart`)
  - CatCard APDUs: `lib/services/hardware/catcard_reader.dart` over the native CCID bridges `ios/Runner/CatCardChannel.swift` (CryptoTokenKit) and `android/.../CatCardUsb.kt` (UsbManager CCID); libwallet speaks the protocol (spec `~/projects/catcard/docs/PHONE-APP.md`)
  - Ledger APDUs: `lib/services/ledger/` - Android USB HID (`android/.../LedgerUsb.kt`) and BLE (`flutter_blue_plus` pinned to 1.x: 2.x needs a commercial license)
  - Air-gapped: `screens/wallet/widgets/airgap_scan_screen.dart` (animated UR/BBQr scan), `airgap_sign_sheet.dart`
  - Add flow: `screens/wallet/add_hardware_wallet_screen.dart`
  - Ledger device management (`screens/wallet/ledger_manage_screen.dart`, from wallet details): firmware status and updates, genuine check, app install/remove, all through libwallet's manager routes (device on its dashboard). A sign that needs a missing app offers to install it (`offerLedgerAppInstall` → `widgets/ledger_app_install_dialog.dart`)
- **Models**: `lib/models/` - StakingPool, UserStake, TokenAccount deserialization matching on-chain layout
- **Screens**: Home, Incinerator, Staking Pools, Staking Detail, Token Info, About
- **Widgets**: CatLogo, TibaneCard, GradientButton, WalletButton

## Key Constants

- Helius RPC: `mainnet.helius-rpc.com` with API key in `solana_constants.dart`
- ChiefStaker Program: `3Ecf8gyRURyrBtGHS1XAVXyQik5PqgDch4VkxrH4ECcr`
- $ChiefPussy Mint: `DRtvTCzfiKGhCVREmBbZdN9sB8PHeq9KdRZ3VmFhpump`
- Reference site: `tibanenet` (Vue 3 + TypeScript, separate repository)

## Build

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

## Notes

- Wallet connection uses MWA (Mobile Wallet Adapter) for Seeker integration
- MWA stub in wallet_service.dart - needs `solana_mobile_client` package for production
- Account deserialization matches the TypeScript in tibanenet/src/lib/staker.ts
- App ID: `net.tibane.tibaneapp`
