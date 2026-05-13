# TibaneApp

Non-custodial cryptocurrency wallet for the Solana Seeker, built in Flutter
on top of [libwallet](https://pub.dev/packages/libwallet).

Tibane is a self-custodial wallet that interacts with public, permissionless
DEX aggregators (Jupiter Ultra, dFlow, 1inch). User keys live on the device
under a 2-of-3 threshold-signature scheme (device share, second-factor share,
password). The app never custodies funds and is not in the transaction path.

## Features

- **Multi-chain accounts**: Solana, EVM, Bitcoin (HD) via libwallet's MPC
  wallets.
- **Send / receive**: address book + ENS / SNS resolution, pre-flight tx
  simulation, BTC HD address rotation.
- **Swap**: Jupiter Ultra & dFlow on Solana, 1inch on EVM, gated on
  libwallet's per-chain availability check.
- **Staking**: ChiefStaker pools for the Tibane Thecat ($ChiefPussy) token.
- **dApp browser**: in-app WebView with `window.ethereum` / `window.solana`
  injection via libwallet, plus a WalletConnect v2 hub.
- **In-app wallets**: create / import (mnemonic + probe + promote), export
  encrypted backup, biometric unlock, password rotation, device-share
  reshare, cloud backup via the system auto-backup directory.

## Project layout

```
lib/
  constants/        # Solana program IDs, mints, RPC endpoints
  models/           # On-chain account / pool deserialization
  screens/          # UI: wallet dashboard, swap, browser, settings, etc.
  services/         # WalletService (façade) + MWA / libwallet backends
  theme/            # Dark theme matching tibane.net
  widgets/          # Reusable UI bits (cards, buttons, chip)
```

Architecture notes are in `CLAUDE.md`.

## Building

```bash
flutter pub get
flutter analyze
flutter run                  # debug on a connected device
flutter build apk --release  # Android
flutter build ipa --release  # iOS (App Store)
```

### Configuration

A few values are wired into `lib/constants/solana_constants.dart`:

- `heliusRpcUrl` — Solana RPC endpoint. Replace with your own
  [Helius](https://helius.dev) URL for production.
- `walletConnectProjectId` — WalletConnect Cloud project id. Empty disables
  WalletConnect; set it to a real id from
  [cloud.walletconnect.com](https://cloud.walletconnect.com) to enable v2
  pairing.

### Fastlane (optional)

Both `android/fastlane` and `ios/fastlane` are configured. The iOS Appfile
reads your Apple ID from the `FASTLANE_USER` environment variable; the
Android Play Store credentials JSON is gitignored and must be provided
locally.

## Contributing

Issues and PRs welcome. This is the public source for the
[Tibane app](https://tibane.net) — open-sourced so the wallet code can be
audited and forked. Please open an issue before large feature work so we can
align on direction.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Karpeles Lab Inc.

The Tibane name, logo, and "Tibane Thecat" / $ChiefPussy branding remain
trademarks of Karpeles Lab Inc and are not covered by the MIT grant. If you
fork this app for redistribution, please use your own branding.
