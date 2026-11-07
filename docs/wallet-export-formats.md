# Wallet export formats

Settings exports the explicitly selected wallet, without switching the active
account or modifying its keys:

- Ordinary mnemonic wallets reveal their BIP-39 words through the official
  `wallets.exportSecret` API. Any BIP-39 passphrase is displayed separately.
- Multichain seed wallets appear once. Both curve members are authenticated
  and their words/passphrase compared before revealing one recovery phrase.
  Only explicitly grouped members are combined; matching names are not enough.
- MPC wallets export the existing encrypted JSON backup bundle.
- Wallets newly restored through `importFromBackup` keep JSON as their export
  format, even when their underlying protocol is mnemonic. Only wallet IDs and
  boolean import-origin markers are persisted, not passwords or recovery words.
- Historical mnemonic wallets without an origin marker default to phrase export.
  Their past import method cannot be reconstructed reliably from SDK metadata.
- Imported private-key accounts retain their separate Manage Accounts export.

Phrase disclosure requires the selected wallet's password and explicit warning
acknowledgment. The backend rejects MPC, unsupported, changed and backup-origin
wallets before returning a phrase. No plaintext export file or native error log
is created. Leaving the app hides the phrase and invalidates an in-flight reveal.
The user can explicitly copy the words or the separate BIP-39 passphrase.

Coverage includes the official native library with disposable Solana/Ethereum
fixtures, wrong passwords, restored-backup routing, wallet-change races,
clipboard operations, lifecycle cancellation, and the four supported UI locales.
