# App-side audit fixes - 2026-10-23

Scope: app 0.1.13+79 with the official, unchanged LibWallet 0.5.5.
This supplements [the original audit](app-audit-2026-10-23.md); that report
records the pre-fix behavior, not the current implementation.

**2026-11-07 follow-up:** The app now uses official LibWallet 0.5.8. The
previous EVM signing-subset and Bitcoin-family history limitations are covered
by new native regression expectations. See [the update report](libwallet-0.5.8-update.md)
for what was verified and what still needs live/device testing. The 0.5.5
findings below are historical.

**2026-11-06 follow-up:** A05 no longer blocks seed import. Recovery phrases
are imported as ordinary single-key mnemonic wallets, without MPC promotion
or email/SMS verification. See [current seed-import behavior](libwallet-0.5.5-mnemonic-mpc.md).

## Implemented

| Finding | App-side resolution |
| --- | --- |
| A01 | Browser requests require a per-document capability injected only in the main frame. Strict envelopes, JSON-encoded response IDs, navigation guards, active-tab checks and permission-filtered events prevent reuse across documents. Native pending approvals are serialized and routed to their originating operation, including WalletConnect. Remote HTTP pages cannot access the provider. |
| A02 | Authenticate every wallet in an isolated temporary store before live import. Restore ed25519 and secp256k1 backups; duplicate IDs never overwrite current generations. Commit only new wallets. Compensating rollback attempts every added wallet; incomplete cleanup has a specific localized warning. |
| A04 | ETH/ERC-20 preflight and submission share a chain-specific transaction builder. Simulation uses the public sender, correct native value and ERC-20 contract/calldata; signing uses the corresponding account ID. |
| A06 | Password-only MPC uses two Password authorizers; biometric wallets use StoreKey + Password. Management actions are gated by the actual committee instead of assuming every wallet has StoreKey. |
| A07 | Explicit wallet groups rotate together, with all credentials checked before mutation. A secret-free progress journal supports retries after partial completion. Already-updated wallets are not reshared again. |
| A08 | Automatic backups retain separate encrypted bundles for each logical wallet, including its explicitly linked technical wallets. Serialized writes and temporary-file rename protect the existing archive. The UI lists saved wallets and does not claim that a local write proves cloud upload. |
| A09 | Persistent wallet-ID relationships replace name/time heuristics. New grouped creations record their relationship, and new backup bundles carry an app manifest that is stripped before native restore. |
| A10 | Swap holdings, quote and execution state are invalidated on account/network changes; late responses cannot restore an old account's actionable quote. SEND and shared authorizers also check their original context. |
| A11 | SEND, staking and partial burn parse decimal text directly into BigInt base units, avoiding floating-point rounding of submitted amounts. |
| A12 | Non-finite/exponent/oversized/excess-precision input is rejected. Widget regressions cover invalid pasted amounts without simulation or an uncaught exception. |
| A13 | Bitcoin MAX retains the selected UTXOs and fee rate through preflight and signing. Recipient, amount, asset, account or network edits invalidate the cached plan; changed MAX amounts are rejected. Native validation still checks current spendability. |
| A14 | EVM/Bitcoin payloads decode as hex, Solana as base64. Approvals show SDK effects, sender/recipient, fees and warnings; raw bytes are secondary. Blocking warnings/reverts disable approval. Decode/UI failures are rejected instead of leaving requests unresolved. |
| A15 | Signing failures propagate visibly and stop the batch. If earlier submissions succeeded, the error retains those signatures and tells the user to check Activity before retrying. |
| A16 | SEND and staking initially say submitted, not confirmed. A transaction hash alone no longer produces a confirmed-success claim. Activity can show available chain confirmation/failure data. |
| A17 | History and cache scope include network and account; EVM comparisons ignore case, Solana/Bitcoin comparisons do not. Filtering can scan additional pages, and Activity exposes Load older. Bitcoin-family history limitations are visible. |

New generic messages have English, Portuguese, French and Japanese translations.

## Important Behavior And Limits

- Legacy wallets without a persisted relationship remain separate, even when
  they have the same name and creation time. This is deliberate: no destructive
  operation should guess ownership. Linking old wallets requires a future
  user-confirmed migration; this change does not invent missing relationships.
- Password rotation is resumable, not an atomic remote transaction across curves.
  If interrupted, retain both old and new passwords and retry with the same pair.
  Offline native tests preserve addresses, validate new signatures and verify
  backup passwords for Solana and Ethereum. A real RemoteKey/2FA ceremony was
  not performed.
- Backup restore uses staged validation and compensating cleanup, not a new
  transactional primitive inside LibWallet. If cleanup itself fails, the app
  tells the user to keep the backup and inspect Manage wallets before retrying.
- Original automatic backups are preserved as a legacy entry. They are not
  silently assigned to whichever wallet happens to be active.
- Raw private-key imports remain outside MPC wallet backups. Export their
  private keys separately through Manage accounts.
- Browser boundary tests use offline JavaScript fixtures and fake transports.
  A real WKWebView iframe/navigation test and real WalletConnect relay test are
  still needed before release. Structured previews depend on native SDK effects;
  unknown effects remain explicitly warned, not interpreted as safe.
- A submitted transaction is not guaranteed to confirm. Live chain/provider,
  device-keystore, cloud-sync and remote fleet behavior were not certified.

## Still For Mark / Provider Configuration

1. **A03: EVM MPC signing subset.** Official native 0.5.5 rejects two of three
   local participants with `DKLs signing requires all shares to be unlocked`.
   Offline all-three control succeeds. The app was not changed to request the
   recovery share on every payment. This blocks the affected EVM MPC signing
   flow even though ETH/ERC-20 preflight payloads are now correct.
2. **A17 external history coverage.** Bundled BTC/BCH/LTC/DOGE history providers
   are absent. The app now states the limitation; complete external/incoming
   backfill requires a supported provider/configuration, not just UI changes.

The earlier A05 native migration limitation remains characterized, but that
operation is no longer requested by the app's import flow. A passing test
means the known limitation is reproducible, not that it has been fixed.

## Verification

- Full offline suite: 738 passed, 11 opt-in live-network tests skipped, no failures.
- `flutter analyze`: no issues found.
- ETH and ERC-20 loopback-native simulation tests now run in the default suite;
  they are no longer skipped expected failures.
- Native tests use generated fixture credentials and temporary databases.
  No real keys, clipboard, simulator wallet database or backup contents were read.
- No real transfers, broadcasts, 2FA requests, app launches or simulator restarts.
- Full test output: `/tmp/tibane-app-audit-2026-10-23.log` (local, not committed).

Focused regression areas include exact amounts, stale quotes, explicit groups,
whole-bundle validation, EVM-only/duplicate restore, partial rollback, concurrent
automatic backups, partial password rotation and resume, document capabilities,
approval ownership, batch failures, authorization context and network history.
