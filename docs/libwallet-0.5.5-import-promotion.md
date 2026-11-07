# Imported Solana account identity after MPC promotion

Observed with the official LibWallet 0.5.5 on 2026-10-21.

Update 2026-10-22: the private-key import promotion feature has been removed
from the app for both Solana and Ethereum. Imports now remain single-key
accounts, with private-key export available through Manage Accounts. Native
MPC creation and mnemonic import/restore flows are unchanged. The observations
below are retained as historical diagnosis, not a claim that the root cause
was isolated or fixed.

- Expected imported address, confirmed by the user:
  `CBcWENrpEfVBcU9gu5b5mdSBsfyzkV8UyPXenSniWS3o`
- The simulator's promoted `pmFEES` account currently has:
  `8DviqTY9qpDCpxKyWhp9hzB3xoUZnTJEN3Pa89d4PiDt`
- Its wallet has threshold 1 and generation 1. Its stored public key matches
  the unexpected address, so this is not merely an abbreviated-label problem.
- The app's import path verifies the imported address against the supplied
  Solana seed before proceeding. Promotion uses `wallets.promote`, not create.
- Offline tests with a public RFC8032 fixture preserve identity with three
  local StoreKeys, and with two StoreKeys plus a Password. These controls do
  NOT reproduce or validate the production RemoteKey/fleet path.

Please investigate the complete StoreKey import -> StoreKey + RemoteKey +
Password promotion, including any post-promotion public-key/account repair.
Wallet public key, original account ID/address, and signing identity must all
remain unchanged, including after refresh and restart.

## Previous App Containment

- Imported Solana promotion was temporarily disabled before any mutation.
  Standard imports and signing remain available; existing native MPC wallets
  are unaffected. This is containment, not a fix to the underlying ceremony.
- Other promotion results were checked for wallet/public-key identity changes.
- No user secrets were inspected, exported, or logged during investigation.
- Existing promoted user wallets have not been edited, deleted, or repaired.
  No transactions were signed or broadcast from them.

Private-key export now uses the official `wallets.exportSecret` only for an
authorized single-key imported root account. It never switches the active
wallet. MPC and derived-account private-key export is refused.
