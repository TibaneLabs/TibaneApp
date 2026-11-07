# Seed import and MPC migration in LibWallet 0.5.5

## Current App Behavior - 2026-11-06

Imported recovery phrases now stay ordinary mnemonic wallets, as requested.
The app calls `importMnemonic` with a single Password protector and derives
the selected network's standard accounts using that password. It does not
create StoreKey/RemoteKey participants, request email/SMS, or call
`promoteMnemonic`. The password protects the import locally; it does not change
the recovery words or their derivation.

Solana and Ethereum native fixture tests cover single-key signing, rejecting a
wrong password, additional account derivation, encrypted backup/restore,
duplicate detection and cleanup. Existing accounts and active selection are
preserved. This is still first-account import, not automatic discovery of every
previously used derivation index. Normal private-key import is unchanged.

The unsupported Solana promotion below remains a native capability limitation,
but is **no longer a blocker for the app's recovery-phrase import**. The old
migration helper remains only as an audit reproduction, not a screen/backend
import path. The following sections describe the earlier MPC migration flow.

## Confirmed Problems

1. The app called `Wallet:promote` on a mnemonic-backed wallet. The native
   library rejects that schema and directs callers to `Wallet:promoteMnemonic`.
   This failure happens after email-code verification; it is not a wrong code.
2. Using the correct endpoint still rejects Solana in the official 0.5.5 native
   runtime: `promoteMnemonic: curve ed25519 not yet supported (secp256k1 only)`.
   The Dart API documents ed25519/FROST support, but the published Rust handler
   documents secp256k1-only support. This requires a library release fix.
3. Migration returns a new technical wallet, not an account. A caller must create
   the destination account explicitly. `Account.list(Wallet: ...)` also returns
   other wallets' accounts in this runtime; it cannot prove destination identity
   unless the account's `wallet` field is checked.

Native reproduction uses a temporary database and the public BIP-39
`abandon ... about` fixture. It performs no email verification, broadcasting,
or access to real-wallet data. The macOS binary reports `0.5.5`; its SHA-256 is
`67fe14e46cd0a43edb62b02f04e81b4ed43918710404402e4a87e14a84eda4cc`, matching
the official release asset.

Sources:
- <https://github.com/KarpelesLab/libwallet/releases/tag/v0.5.5>
- <https://github.com/KarpelesLab/libwallet/blob/v0.5.5/rust/src/handlers/wallet.rs#L158>

## App Integration

`importMnemonicAsMpc` now creates the first standard source account using the
mnemonic unlock credential, passes that exact derivation path and explicit curve
to `promoteMnemonic`, creates the destination's root account, and verifies its
wallet ownership and address before persisting the device key. The temporary
source is deleted only after these checks and local custody succeed.

On failure, cleanup is limited to wallets created by this attempt. Previously
existing wallets and the previously selected account are preserved. No fallback
to a single-key wallet or a different-address MPC wallet is performed. Solana's
native unsupported error has a specific translation in all four app languages.

This is a first-account migration, not discovery of every account under the seed.
The secp256k1 branch migrates the first Ethereum account; it must not be presented
as migrating the seed's independent Bitcoin accounts too. Those require separate
chain migrations and account-selection work.

## Verification

`test/mnemonic_promotion_integration_test.dart` verifies the native Solana
limitation, the first Ethereum address against a public known vector, explicit
destination account ownership, preservation of an existing wallet/account,
cleanup when device-key persistence fails or throws, and restoration of the
previous account selection. Ethereum message signing is offline with three local
Password participants, not the production RemoteKey committee. The 0.5.5 native
DKLs endpoint required all three fixture shares to be unlocked for that control;
this does not validate production two-share EVM signing.

No end-to-end Solana MPC seed import can pass until the native limitation is fixed.

## Message For Mark

In LibWallet 0.5.5, Solana mnemonic import cannot be promoted to MPC. `promote`
rejects the mnemonic schema and says to use `promoteMnemonic`, but that endpoint
returns `curve ed25519 not yet supported (secp256k1 only)`. Reproduced with the
official 0.5.5 native binary and a public BIP-39 test vector, without a remote
participant or broadcasting. The Dart API documents ed25519 support. Please
implement/release native Solana mnemonic migration and test address preservation
and signing with the production StoreKey + RemoteKey + Password committee.
