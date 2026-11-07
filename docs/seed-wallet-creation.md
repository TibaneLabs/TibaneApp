# Ordinary seed-wallet creation

Enabled with official LibWallet 0.5.8. Create wallet > Generate Seed Phrase
now opens a dedicated ordinary-wallet flow, separate from MPC creation.

1. Choose a name. New wallets always use 12 words and open Solana, Ethereum,
   Bitcoin, Bitcoin Cash, Dogecoin and Litecoin, matching MPC's network set.
   There is no network or word-count selector. Import accepts other supported
   phrase lengths and opens the same six networks automatically.
2. Generate and validate the phrase through native LibWallet, without storing
   a wallet yet. Words are hidden until explicitly revealed.
3. Write down the words and acknowledge the backup, then continue directly to
   the password step. There is no word-entry confirmation screen.
4. Choose and confirm a local password. The multichain mnemonic-import operation
   imports the same words/passphrase into ed25519 and secp256k1 members and
   persists their explicit logical-wallet relationship. Default raw accounts
   are Solana, Ethereum and Bitcoin; the Bitcoin backing provides the four
   Bitcoin-family contexts, just as in MPC. No RemoteKey or promotion is used.
5. Open the created wallet through the existing account-selection service.
   An activation failure retries activation only, never wallet creation.

The generated phrase is never intentionally written to preferences, clipboard,
logs or an app-created plaintext file. The phrase list and password controllers
are cleared after creation/disposal; passwords are cleared and
words hidden when the app leaves the foreground. This reduces exposure but is
not a promise of guaranteed Dart-memory erasure or OS screenshot prevention.

Both creation and import appear as one wallet in the sidebar and export screen.
Ordinary seed wallets authorize account derivation and signing through a direct
password dialog, not the MPC share-selection sheet. The password is collected
only for that operation; leaving the foreground clears the field and cancels
the prompt. MPC wallets retain their existing share-selection requirements.
Export verifies that all selected seed members contain identical words and
passphrase before revealing one phrase. Unrelated or historical single-curve
wallets are not automatically combined by name or creation time.

If either curve, account creation or grouping fails, compensating cleanup is
restricted to IDs returned by this operation. Accounts are explicitly deleted
before wallets because native wallet deletion does not cascade to accounts.
Existing wallets, accounts, active account and group metadata are preserved.
An incomplete cleanup gets a localized warning to keep the recovery words and
check Manage Wallets before retrying.

Coverage includes widget validation, four locales, narrow/large-text layouts,
background hiding, pending work, retries, account activation and setup-menu
completion. Native tests generate fresh unfunded phrases for both lengths and
curves, export the same words, sign locally and re-import on a second temporary
store with a different local password to reproduce the same derived account.
Multichain tests verify all six addresses, sidebar order, optional passphrases,
group export, duplicate rejection, cleanup, concurrency and context changes.
The creation UI remains fixed to 12 words on every supported network.
No real user keys, funds, simulator store or clipboard are used.

These checks do not certify live transfers or automatic discovery of every
derivation path used by other wallets. Fixture screenshots cover the three
creation steps at 320- and 393-point widths, without launching the simulator.
