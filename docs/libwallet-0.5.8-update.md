# LibWallet 0.5.8 integration - 2026-11-07

The app now resolves the official, unchanged pub.dev package and native
release 0.5.8. Only LibWallet changed during dependency resolution; no
local library fork or secret-storage migration was introduced.

Sources:
- <https://pub.dev/packages/libwallet/versions/0.5.8>
- <https://github.com/KarpelesLab/libwallet/releases/tag/v0.5.8>
- <https://github.com/KarpelesLab/libwallet/blob/v0.5.8/dart/CHANGELOG.md>

## Previously Pending Items

- **EVM MPC signing:** native message-signing regressions now require every
  pair of three participants to succeed, in either order. Solana remains a
  control; all three participants still work, and a single participant is
  rejected. The former expected EVM failure is no longer accepted.
- **BTC/BCH/LTC/DOGE history:** network metadata now advertises `modchain`.
  Loopback-native regressions exercise receive/change address scanning,
  duplicate removal, exact eight-decimal amounts, unconfirmed transaction
  exclusion and repeat backfill. The app already invokes this provider and
  only displays its limited-history notice when no provider is available.
- **Mobile seed generation:** the official native API generates and validates
  12/15/18/21/24-word phrases, with 12 as default. Tests verify the API does not
  create a wallet. The initial dependency update left seed creation disabled;
  the subsequent [ordinary seed-creation flow](seed-wallet-creation.md) now
  enables it with phrase backup, confirmation and a local password.

Ordinary seed/private-key imports remain ordinary wallets. No MPC promotion
was reintroduced. The new Vault API is available but existing app keystore
custody was not migrated implicitly. Android already uses
`FlutterFragmentActivity`, as required by the new plugin.

## Native Artifacts

CocoaPods installed LibWallet 0.5.8. SHA-256 values match the official release:

| Artifact | SHA-256 |
| --- | --- |
| macOS arm64 | `b5019a43fb36c474b3b4084825bccdfdfd949cd198da98815427e6a798067381` |
| iOS arm64 | `1c1fd1afaa976d6721d67754631d6a6d59f59012782b32e321c1ab835022e13f` |
| iOS Simulator arm64 | `ac52dde4000c027fda7c34e5394a3bd45431b0617539c0f7f49f59da0d86b8c0` |

## Verification And Limits

- Full suite: **874 passed, 11 opt-in live-network tests skipped, no failures**.
- `flutter analyze`: no issues found.
- Full local test log: `/tmp/tibane-libwallet-0.5.8-tests-final.log`.

Tests use temporary stores, generated fixture credentials, public BIP39 test
vectors and local RPC fixtures. No real wallet database, key or clipboard was
read; no funds were moved. Live network/provider and remote 2FA tests are not
included in this verification.

The universal iOS simulator build could not complete: Flutter's debug engine
framework does not contain both requested `arm64 x86_64` architectures.
An arm64-only build was not authorized. This is not a successful iOS build
certification. No simulator or app was launched or restarted.

Loading new native code requires stopping the existing `flutter run` process
and running it again. A Dart hot reload/hot restart cannot replace the native
library; the simulator itself does not need restarting.
