# Derived accounts and older backups

Verified on 2026-10-22 with the official LibWallet 0.5.5 native library.

## Supported Recovery

A backup stores the wallet and the account records present when it was
exported. It cannot contain records created later. For accounts derived from
the same MPC wallet, creating the same chain's accounts again after restoring
an older backup reproduces the same indices, paths, and addresses.

The app's Create Account flow uses `AccountsService.createAccount` and
`LibwalletBackend.createAccount`, which ask LibWallet for the next account
index in the selected wallet/type. The index is not calculated from account
names, the visible account count, or imported accounts in other wallets.

Example:

1. Create the native account at index 0 and export a backup.
2. Create derived accounts at indices 1, 2, and 3.
3. Restore the original backup on another device. Only index 0 is listed.
4. Choose the same wallet and chain in Create Account three times.
5. Indices 1, 2, and 3 have the original addresses. The next creation uses 4.

Names entered after the backup are not known to that file. Recreated accounts
can have different names without changing their addresses. A newer backup
remains useful for restoring the complete account list and names directly.

## Boundaries

- No automatic on-chain discovery was added. Unknown or skipped indices may
  require further account creation or an explicit recovery mechanism.
- Imported private keys and independently created MPC wallets are not derived
  accounts; they cannot be recovered from another wallet's derivation tree.
- Address recreation does not repair stale signing shares after password,
  device-key, or remote-key rotations. Signing recovery is a separate flow.

## Regression Coverage

`test/libwallet_0_5_1_account_integration_test.dart` verifies this scenario for
Solana and Ethereum through the app's account creation adapter, using temporary
source and restore databases. The Ethereum case includes the native Bitcoin
backing account to verify that indices remain chain-specific. The tests also
check that restoring the old file again does not duplicate recreated accounts.
No user wallet data, remote signing sessions, or broadcasts are involved.
