# LibWallet 0.5.5: Account wallet filter is ignored

## Confirmed Reproduction

Using the official Dart package and matching official macOS native binary:

1. Import two public Ed25519 fixture keys into different wallets.
2. Create one Solana account in each wallet.
3. Call `client.accounts.list(wallet: firstWallet.id)`.
4. The response contains accounts belonging to both wallets, not just the first.

Expected: every returned account's `wallet` equals the requested wallet ID.
Please enforce the `Wallet` filter in the native `Account GET` handler and add
an end-to-end Dart/native regression test.

## Impact And App Protection

The app previously trusted this filter when removing an imported technical
wallet. It consequently deleted unrelated account records. Read-only inspection
of the affected simulator found five surviving wallets but zero account rows.
This observation does not mean that the wallet keys were deleted.

The app now checks ownership explicitly before deleting each account, including
a fresh `accounts.get(id)` check. Wallet selection, restore and device-transfer
paths also filter returned accounts locally. No library code was patched.

If a surviving wallet has no account records, the app verifies the list again
and recreates its standard index-zero accounts through the official API,
despite stale "defaults already ensured" flags. It does not guess higher
derivation indices or claim to recover deleted custom account names.

Regression: `test/libwallet_account_deletion_integration_test.dart` uses only
temporary databases and public fixture keys. It verifies isolation, partial
recovery, and index-zero address preservation. It never broadcasts transactions.
