# Biometric Authorization for Ordinary Wallets

Settings > Security & Privacy exposes an opt-in switch for the selected
ordinary seed wallet or private-key-imported account. MPC and external
wallets cannot enroll through this feature.

Seed enrollment verifies the password against LibWallet's Password public
key before saving it in `biometric_storage`. Both technical curve wallets
in an explicit seed-wallet group are covered, including derived accounts.
Private-key imports enroll their existing local StoreKey credential; no
new wallet password or MPC conversion is introduced.

The protected entry is bound to the wallet, protocol and key generation.
Preferences contain only a non-secret binding hash. The iOS plugin uses
`biometryCurrentSet` and `WhenPasscodeSetThisDeviceOnly`; authentication
context reuse is not enabled. Credentials are not included in wallet
exports and must be enrolled again on another device.

Each signing operation reads the protected entry again. Transaction
review remains required. Failed seed authentication can fall back to the
password dialog. Failed private-key authentication aborts without trying
the existing no-auth StoreKey path. Disabling requires device-owner
authentication, with the OS device-passcode fallback available. Wallet
deletion and full reset remove the new enrollment and protected entry.

This is transaction authorization, not an app-wide screen lock. Export
and recovery flows retain their separate authorization rules. MPC shares,
wallet addresses, derivation and backups are unchanged.

Tests use injected biometric storage and unfunded local LibWallet
fixtures. Face ID hardware prompts still require testing on an iPhone.
