# Ellipx-Parity Migration Plan

> **Audience:** a future Claude (or engineer) implementing the migration of the
> Tibane app toward the Ellipx architecture. This document captures the target
> design, the decisions already made by the product owner, exact file
> references in **both** repos, and a phased plan with tests. Read it top to
> bottom before touching code.

## 0. How to use this document

- **Repos**
  - Tibane (this app): `/Users/jeremyvinai/Workspace/atonline/tibaneapp`
  - Ellipx (the blueprint): `/Users/jeremyvinai/Workspace/atonline/ellipx-mobile-app`
  - libwallet (shared engine, Dart pkg): `~/.pub-cache/hosted/pub.dev/libwallet-0.4.68/`
  - libwallet (Go source, if present): `/Users/jeremyvinai/Workspace/atonline/libwallet`
- Both apps run on the **same `libwallet` FFI engine** and the **same three TSS
  share types** (device `StoreKey` + 2FA `RemoteKey` + `Password`). The crypto
  and the wallet data model are shared. **Everything being migrated is in the
  management layer above libwallet**, not the cryptography.
- **Working principles** (carry these into every phase):
  1. **Zero-data-loss migrations** — any change to persisted data must verify
     the new copy before deleting the old (idempotent, retry-safe). Wallet keys
     are irreplaceable.
  2. **Unit tests per phase** — every phase ships its own tests in the same
     change (follow the existing pattern: extract a pure decision function,
     test it; device-verify the UI/keystore parts).
  3. **Leave bug/behavior changes uncommitted until validated on device** —
     biometric, signing, and migration paths can't be fully unit-tested.

---

## 1. Current state vs target (one-paragraph each)

**Tibane today** — Dual backend (`WalletKind.mwa` external/Seed Vault **and**
`WalletKind.inapp` libwallet MPC) behind `WalletService.active`. **Wallet-centric**:
one wallet is "active", its secrets (`_storeKeyPriv`, `_password`) are cached in
memory by an **app-level `unlock()`**, and you `switchWallet(id, password)` to
change wallets. Device share stored in `flutter_secure_storage` **without** a
biometric gate; biometric is an **optional Settings toggle** that only caches the
*password*. **No forced onboarding** (defaults to MWA, browse without a wallet).

**Ellipx (target shape)** — In-app libwallet only. **Account-centric**: no active
wallet; a single **current account** (`CurrentAccountCubit`) selected from a list
of *all accounts across all wallets*; `setCurrentAccount()` drives balances. **No
lock** — signing is authorized **per transaction** by unlocking shares in a
dialog. The **StoreKey private key itself lives behind biometric**
(`biometric_storage`), read via a biometric prompt at sign time. Biometric is
**mandatory** for a "standard" wallet (enforced at onboarding/creation).

---

## 2. Decisions locked in (from product owner)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Account list across the two backends | **Unified, mixed** — one list showing the MWA/external account(s) AND all in-app MPC accounts; the current account can be either backend. |
| D2 | Onboarding | **Keep "browse without a wallet"**; do NOT force setup at launch. But the MPC **creation flow** should mirror Ellipx (steps + biometric enforcement). |
| D3 | Biometric storage package | **Adopt `biometric_storage` + `local_auth`** (Ellipx parity). See §3.1 for rationale. |
| D4 | Signing model after removing lock/unlock | **Mirror Ellipx** (per-transaction): **Password + biometric StoreKey on every signature** (2-of-3). **S1 is resolved** (§3.2): libwallet needs `threshold + 1` shares, so biometric-alone signing is impossible. StoreKey cached only within a single sign-sheet. |
| D5 | MPC creation on a device **without** biometric | **Password-signable fallback.** Because signing needs 2 shares (S1) and RemoteKey can't sign (D9), the committee must yield 2 shares from the password alone — use **multiple password-derived shares** (Ellipx's "unsafe" trick), e.g. `[Password, Password, RemoteKey]` threshold 1: one typed password unlocks 2 shares to sign, RemoteKey stays for 2FA recovery. Not blocking; clearly labeled lower-security. (Plain `Password + RemoteKey` would be **unsignable** — see §5.2.) |
| D6 | "Add biometric" for **MWA / Seed Vault** wallets | **Nothing extra** — Seed Vault does its own auth; do not add an app-level biometric layer for MWA accounts. (This simplifies Feature 2's MWA scope to "no-op".) |
| D7 | Migration of existing in-app wallets | **Eager one-time screen** at first launch after the update that re-secures the StoreKey behind biometric. |
| D8 | Password-encrypted fallback blob (the device-share copy in SharedPreferences) | **KEEP it** — prioritize recovery. The blob stays as a local, OS-restore-surviving recovery copy. ⚠️ Consequence: password-alone can still reconstruct the device share, so **biometric is a UX/convenience gate, not a hard second factor** (see §3.1 "Security consequence"). This intentionally diverges from Ellipx, which keeps the StoreKey *only* behind biometric. |
| D9 | RemoteKey as a signing factor | **Keep recovery-only** — RemoteKey is NOT used to sign (matches both apps; signing = StoreKey + Password). Consequence: since signing needs 2 shares (S1) and RemoteKey can't supply one, the no-biometric D5 committee must be password-signable on its own (multiple password shares) — see D5 + §5.2. |
| D10 | Account creation in the account-centric model | **Support add-account** — provide an "add account" flow (Ellipx `SharedAccount.createAccount`) so the unified list can grow (more chains / multiple accounts per wallet). |
| D11 | How the external MWA/Seed Vault account enters the unified list | **Explicit connect** — keep an MWA "connect" action; the external account appears in the list **only while connected** (MWA can't enumerate offline). Resolves the §4.2 open question. |
| D12 | Cloud backup / recovery scope for this migration | **Out of scope now** — new wallets recover via the kept password blob (D8) + existing 2FA reshare + device transfer. Ellipx-style iCloud/Drive backup is a later follow-up. |
| D13 | Chain scope of the account-centric model | **Full multi-chain** — every created account (Solana ed25519 + Ethereum/EVM secp256k1, etc.) is fully functional: balances, RPC, send, swap. **libwallet already provides all of this cross-chain** (`client.assets`, `client.networks`, `client.transactions`, `client.swap` — OKX covers Solana + EVM; this is exactly what Ellipx uses). So the work is **migrating Tibane's bespoke, Solana-only app layer onto libwallet's existing multi-chain APIs** — NOT building chain plumbing. Tibane today uses Helius `RpcService` + hard-coded `_solBalance`/`_chiefPussyBalance` + Jupiter swap; replace those with libwallet's chain-agnostic APIs (port Ellipx's `SharedAsset`/`AssetCubit`, swap, transactions). See §4.4 + §4.6. |
| D14 | ClawdWallet / agent wallets in the account-centric model | **Keep separate — do NOT merge into the unified account list.** Agent wallets are phplatform `Crypto/WalletSign` records (NOT libwallet `Wallet`s; absent from `client.wallets/accounts.list()`), **autonomous** (agent + wdrone + a policy-checkpoint mobile share; the user does **not** sign per-tx, no biometric/password), Solana-only, and live in their own "Agents" section (Settings → Connections). The migration (Feature 3) and lock-removal must **leave their key material untouched**. No Ellipx equivalent. See §4.12. |
| D15 | Localization of the new screens | **Inline English string literals** — match Tibane's current convention. Tibane is English-only (`supportedLocales: [Locale('en')]`; **no** `intl` / `l10n.yaml` / `.arb` / `AppLocalizations`; `flutter_localizations` is only for Material/phone-field widget labels). Do **NOT** introduce Ellipx's `intl`/`AppLocalizations` framework in this migration — that's a separate app-wide effort (Ellipx uses it in ~103 files; adopting it means migrating *every* existing Tibane string to `.arb`). New migration / creation / sign-sheet / account-switcher / recovery strings are plain literals; full l10n is a documented follow-up. |

---

## 3. Cross-cutting foundations (do these first / keep in mind throughout)

### 3.1 Biometric storage: adopt `biometric_storage` + `local_auth` (D3) — rationale

**Recommendation: adopt `biometric_storage` + `local_auth`, matching Ellipx.**

Why this over extending the current `flutter_secure_storage`:
- **Lift-and-shift parity.** Ellipx's entire biometric custody is a thin service
  (`ellipx/lib/service/biometric.dart`) over `biometric_storage`, used by its
  creation, signing, device-transfer, and reshare flows. Adopting the same
  package lets us port those flows almost verbatim and keeps the two apps
  convergent (the stated goal).
- **Purpose-built for "secret behind per-read biometric auth."** `biometric_storage`
  is designed to store a single secret and require a biometric prompt on each
  read — exactly the StoreKey custody need. We hit Android quirks this cycle
  using `flutter_secure_storage`'s newer biometric options (`enforceBiometrics`,
  cipher migration, `resetOnError`); `biometric_storage` avoids that surface.
- **Capability check.** Ellipx gates creation on `Biometric.hasBiometric()` via
  `local_auth`. `flutter_secure_storage` has no clean "is biometric available"
  probe; `local_auth` gives it directly (needed for D5's enforce-if-available).

Trade-off / what we keep `flutter_secure_storage` for:
- Tibane has a **password-encrypted fallback blob** (`secure_keystore.dart`,
  `libw_device_share_blob_v1_<walletId>`) that survives OS restore-from-backup —
  Ellipx has no equivalent. **Keep `flutter_secure_storage` for this non-biometric
  recovery copy** (and for the no-biometric `Password + 2FA` wallets from D5).
  So the end state uses **both** libs, with clear roles:
  - `biometric_storage` → the **biometric-gated StoreKey private key** (custody).
  - `flutter_secure_storage` → **non-biometric at-rest fallback** for recovery
    and for no-biometric wallets.
- Document this split prominently so the two don't drift.

> Ellipx references: `lib/service/biometric.dart` (`setSecuredKey`,
> `askSecuredKey`, `hasBiometric`), pkg `biometric_storage: ^5.1.0-rc.5`,
> `local_auth: ^3.0.1`.

#### Data migration & no-loss guarantee (adopting `biometric_storage` does NOT lose data)

`biometric_storage` and `flutter_secure_storage` are **independent stores**.
Adding/using `biometric_storage` does not touch or wipe anything already in
`flutter_secure_storage` — nothing is auto-deleted. Existing data is only ever
removed by the explicit, verify-before-delete migration in **§6.3**.

What exists today for each in-app wallet (`secure_keystore.dart`,
`writeDeviceShare`) — the device share (StoreKey private) is written to **two**
at-rest copies:
1. **No-auth OS-keystore copy** — `libw_device_share_<walletId>` via
   `flutter_secure_storage` (`_iosPlain`/`_androidPlain`). Readable when the
   device is unlocked, **no password**.
2. **Password-encrypted blob** — `libw_device_share_blob_v1_<walletId>` in
   **SharedPreferences** (AES-GCM under the password). Survives OS restore.

Migration target (per **D7** + **D8**):
- **Move copy #1 → `biometric_storage`** (read the no-auth copy — no password
  needed — write to biometric_storage, **read it back to verify**, then delete
  the no-auth copy). Verify-before-delete ⇒ **zero data loss**; on failure the
  old copy stays and it retries next launch.
- **Keep copy #2 as-is (D8)** — the password-encrypted blob remains the local,
  OS-restore-surviving recovery copy.
- **No biometric on the device** → don't move anything; the share stays in
  `flutter_secure_storage` (no loss), and the wallet behaves like a D5
  `Password + 2FA` wallet.

End-state storage roles:
- `biometric_storage` → biometric-gated StoreKey private (primary, custody).
- `flutter_secure_storage` / SharedPreferences blob → password-decryptable
  recovery copy (kept) + storage for no-biometric wallets.

> **Enrollment-invalidation config:** `biometric_storage` can be configured to
> invalidate the stored key when the device's biometric enrollment changes (a
> finger/face is added/removed). Decide this at implementation time — but note
> that **D8 makes it safe either way**: if the biometric key is invalidated, the
> StoreKey is recoverable from the kept password blob (copy #2). Check how Ellipx
> configures `StorageFileInitOptions` / `AndroidPromptInfo` in
> `ellipx/lib/service/biometric.dart` and match it unless there's reason not to.

#### ⚠️ Security consequence of D8 (keep the blob)

Because the password-encrypted blob is retained, **the password alone can still
reconstruct the device share** (decrypt blob → device share), and together with
the Password share that is enough to sign. So with D8, **biometric is a
convenience/UX gate over the StoreKey, NOT a hard second factor** — the real
security floor stays "password = full access," the same as today. This is a
deliberate divergence from Ellipx (which stores the StoreKey *only* behind
biometric and pushes recovery to cloud backup + 2FA reshare). If a future
decision wants true biometric-as-second-factor, revisit D8 (drop the blob) and
strengthen the cloud-backup / 2FA recovery story to compensate.

### 3.2 Signing model & the threshold question (D4) — **READ CAREFULLY**

Findings from the Ellipx code (cite when implementing):
- libwallet sets **`threshold = 1`** by default at wallet creation
  (`libwallet/wltwallet/wallet.go:256`; `multiCreate` takes no threshold param,
  Ellipx `lib/crypto/shared_wallet.dart:15`).
- The libwallet Dart model documents `threshold` as *"Minimum number of key
  shares required to sign"* (`libwallet-0.4.68/lib/src/models/wallet.dart:30`).
- **But** Ellipx's UI + validation require **`threshold + 1` shares** to sign:
  - readiness: `_keys.length >= wallet.keys.length - wallet.threshold`
    (`lib/screens/wallet/widgets/wallet_keys/dialog_wallet_keys_unlock.dart:42`)
  - validation: `if (keys.length < wallet.threshold + 1) error`
    (`lib/crypto/wallet_service.dart:70`)
  - For a standard 3-key wallet with threshold 1 → **2 of 3 shares required**.
- **RemoteKey is dormant at sign time** — the unlock handler is a stub
  (`wallet_keys_unlock.dart:51-52` "nothing for long time"; `wallet_service.dart:65-67`
  `//TODO`). So the two usable shares are **Password + StoreKey (biometric)**.
- **Net Ellipx UX: every signature requires the typed Password AND a biometric
  read of the StoreKey.** The StoreKey is cached only **within a single unlock
  dialog instance** (`wallet_keys_unlock.dart:29,54-56,75`), not across
  transactions or app-wide.

**S1 — RESOLVED from the libwallet Go source.** Signing requires **`Threshold + 1`
shares**, not `Threshold`. The Dart model's "minimum shares required to sign" doc
comment is **misleading** — `Threshold` is the (t,n) "max shares that may be
missing"; you need `t+1` to sign. Proof in the Go source
(`/Users/jeremyvinai/Workspace/atonline/libwallet`):
- `wltwallet/frost_test.go:20` — *"Threshold=1, 3 shares → sign with at least 2
  (T+1)"*; `:46` signs by iterating `w.Keys[:w.Threshold+1]`.
- `wltwallet/join.go:417,620` — `tss.NewParameters(..., len(sids), wallet.Threshold)`;
  tss-lib needs **t+1** parties to produce a signature.
- `wltwallet/promote.go:112` — threshold is constrained `1 ≤ T < len(New)` and
  `New` must have **≥ 2** keys.

**Consequences (these are now settled, not open):**
- **Default standard wallet = 2-of-3.** Every signature needs **StoreKey
  (biometric) + Password**, per transaction — exactly Ellipx. The StoreKey is
  cached only within a single sign-sheet instance.
- **Biometric-only signing is impossible** by construction: min threshold is 1 ⇒
  min 2 shares ⇒ you can never sign with the StoreKey alone. The earlier
  "prefer biometric-only if 1 share works" path is dead — drop it.
- **RemoteKey can't rescue a 2-of-N wallet at sign time** (it's dormant, D9). So a
  no-biometric committee must produce its 2 shares from the password alone — see
  the corrected **D5** in §5.2 (multiple password-derived shares, the Ellipx
  "unsafe" trick).
- Build the sign sheet's "required keys" count as **`wallet.threshold + 1`** so it
  adapts to any committee.

> Note: Tibane today already signs with StoreKey + Password (both cached after
> `unlock`). So the migration's signing change is really about **when** shares are
> collected (per-tx vs cached session) and **how the StoreKey is protected**
> (biometric vs no-auth keystore) — not about which shares.

**"Not-yet-migrated" signing fallback (important during Phases 1–3).** The new
per-tx sign path reads the StoreKey from `biometric_storage`, but a wallet isn't
moved there until the Feature 3 migration runs (and the user may cancel the
biometric prompt, leaving it un-migrated). So the StoreKey read **must fall back**
to the legacy locations when `biometric_storage` has no entry: the no-auth
OS-keystore copy (copy #1) or the password-decryptable blob (copy #2). Implement
the read as: `biometric_storage` → else no-auth keystore → else password blob.
Never assume the StoreKey is already behind biometric.

### 3.3 What "remove lock/unlock" concretely deletes

Removing the app-level lock model (D4) means removing/repurposing:
- `LibwalletBackend.unlock()` / `unlockWithBiometric()` / `lock()` and the
  in-memory `_storeKeyPriv` / `_password` session caches
  (`lib/services/wallet/libwallet_backend.dart`).
- The unlock screen `lib/screens/wallet/inapp_unlock_screen.dart` (becomes a
  per-transaction sign dialog instead; the 2FA-recovery branch moves to an
  explicit recovery entry point).
- The **"Use FaceID / fingerprint to unlock" Settings toggle** and the whole
  optional-password-cache mechanism (`security_privacy_screen.dart`
  `_BiometricToggleTile`; `secure_keystore.dart` `libw_biometric_pw`,
  `writeBiometricPassword/readBiometricPassword`; the
  `_migrateBiometricToAuthRequired` migration + `biometricResetNotice`). Biometric
  becomes **intrinsic to signing**, not an unlock shortcut.
- The Settings **"Lock wallet"** action (`settings_screen.dart`
  `_confirmLockOrDisconnect`) — with no lock concept, this becomes "remove
  account"/"sign out of external wallet" semantics only.
- `isUnlocked` / `isConnected` gates throughout the UI need rethinking against
  the new "current account" model (§4).

---

## 4. Feature 1 — Account-centric model, dual backend, no lock/unlock

### 4.1 Target model (mirror Ellipx, adapted for two backends)

- Introduce a **current account** abstraction at the `WalletService` façade,
  replacing the wallet-centric "active wallet + unlock" model.
  - Ellipx reference: `CurrentAccountCubit` (`lib/bloc/current_account_bloc.dart`),
    `SharedAccount.setCurrentAccount` → `client.accounts.setCurrent(id)`
    (`lib/crypto/shared_account.dart`), persisted inside libwallet.
- **Unified account list (D1):** show
  1. every in-app MPC account: `client.accounts.list()` across all wallets
     (Ellipx: `AccountCubit` → `SharedAccount.getAccounts()`), labeled
     `"<account name> — <wallet name>"` (Ellipx `dropdown_accounts.dart:175`), and
  2. the **MWA/external** account(s) currently connected via
     `MwaWalletBackend`.
- `setCurrentAccount(account)`:
  - if the account is **in-app**: route signing to `LibwalletBackend`, set
    libwallet's current account, set the account's wallet as the one whose
    StoreKey will be biometric-read at sign time.
  - if the account is **MWA**: route signing to `MwaWalletBackend`.
  - then **load that account's assets** for its chain (see §4.4 — under **D13**
    this is a generic per-account asset list, NOT the current bespoke
    `_solBalance`/`_chiefPussyBalance` fields, which only work for Solana).
- **No lock/unlock** (see §3.3). Nothing is "unlocked"; the current account just
  determines which backend signs and (for in-app) which wallet's shares to
  collect per transaction.
- **Add-account (D10).** Provide an "add account" flow so the unified list can
  grow — additional chains and/or multiple accounts per in-app wallet. Port
  Ellipx `SharedAccount.createAccount(walletId, name, type)`
  (`lib/crypto/shared_account.dart`); the account-add UI lives near the account
  switcher. (MWA accounts are added by connecting, per D11, not via this flow.)

### 4.2 The unified account data model

Define one app-level account type spanning both backends and all chains — a
`UnifiedAccount` view-model on `WalletService`:
- `backend`: `inapp` | `mwa`
- `chain`: libwallet network/type — `solana`, `ethereum`, … (selects the libwallet
  network + the asset/RPC/send path)
- `address`: chain-native address string
- `label`: in-app `"<account name> — <wallet name>"` (Ellipx
  `dropdown_accounts.dart:175`); MWA `"External (Seed Vault)"`
- in-app only: `walletId`, `accountId`, `curve` (libwallet ids needed to sign and
  to fetch assets)
- stable identity: in-app → `accountId`; MWA → `"mwa:" + address`

Sources:
- **in-app**: `client.accounts.list()` across all wallets (libwallet
  `Account{id, wallet, type, address}`), enriched with the wallet name.
- **MWA**: the single connected pubkey from `MwaWalletBackend`. Seed Vault is
  **Solana-only**, so an MWA account is always `chain: solana`.

Keep the assembly as a **pure builder** —
`buildUnifiedAccounts(inappAccounts, walletsById, mwaAddress?)` — so it's
unit-testable (follows the existing `pickNextActive`/`walletDetailActions`
pattern).

### 4.3 Per-transaction signing contract (replaces lock/unlock — the crux)

`WalletBackend` (`lib/services/wallet/wallet_backend.dart`) exposes `signMessage`
/ `signTransactions` / `signAndSendTransactions`, all of which **assume an
already-unlocked backend** (LibwalletBackend signs with cached `_storeKeyPriv` +
`_password` via `_signingKeys()`). There are **38 `ensureUnlocked`/`isUnlocked`
call sites**. Removing lock means each sign authorizes **per call**.

New contract:
- Add a façade entry on `WalletService`, e.g.
  `Future<List<Uint8List?>> signTransactions(BuildContext ctx, List<Uint8List> txs)`
  (+ `signAndSend`, `signMessage`) that:
  1. resolves the **current account** + its backend;
  2. **in-app** → opens the per-tx **sign sheet** (port Ellipx
     `dialog_wallet_keys_unlock.dart` + `wallet_keys_unlock.dart`) which collects
     the required shares — StoreKey via biometric (read from `biometric_storage`,
     with the §3.2 fallback chain) + Password typed — into `List<SigningKey>`,
     then calls libwallet `accounts.signTransaction(accountId, tx, keys:)`;
  3. **MWA** → routes to `MwaWalletBackend` (Seed Vault's own auth; no app sheet, D6).
- **How many shares** = per §3.2 / **S1**. Derive the sheet's "required keys" from
  the wallet's `threshold` so it auto-adapts (Solana StoreKey+Password, or the
  fallback committees).
- Replace each of the 38 `ensureUnlocked`-then-sign sites with one
  `authorizeAndSign(...)` call. `isUnlocked` checks become a `canSign` /
  `hasCurrentAccount` getter — nothing is persistently unlocked.
- **The `WalletBackend` interface change is the ripple center.** The signing
  methods now take per-call authorization (a `BuildContext` to drive the sheet,
  or pre-collected `List<SigningKey>`). Delete `LibwalletBackend._signingKeys()`
  and the `_storeKeyPriv`/`_password` session fields.

### 4.4 Assets / balances — use libwallet's multi-chain API (D13)

Tibane today: hard-coded `_solBalance` + `_chiefPussyBalance` on `WalletService`
plus a Helius SPL scan (`discoverHoldings` / `RpcService`) — **Solana-only and
bespoke**. Replace with libwallet's chain-agnostic asset API (exactly Ellipx's
model — libwallet already handles every chain):
- Port Ellipx `SharedAsset` + `AssetCubit` (`lib/bloc/asset_bloc.dart`) onto
  `client.assets.list()` for the current account + the `client.balanceChanges`
  stream (Tibane already bridges this as `balanceTick`).
- Home renders a **generic per-account asset list** instead of two fixed
  balances. `$ChiefPussy` can stay a *featured/pinned* token but is no longer the
  balance model.
- Drop the bespoke `RpcService` balance path (keep only any Solana extra libwallet
  doesn't surface). libwallet selects the right RPC per network.

### 4.5 Dual-backend reconciliation

- **MWA is Solana-only** (Seed Vault). EVM / other-chain accounts are therefore
  **always in-app**. The unified list mixes in-app (any chain) + MWA (Solana).
- **MWA entry — D11**: explicit connect; shown only while connected. Wire the
  connect action into the account switcher; check `mwa_wallet_backend.dart`
  (`connect` / `publicKey` / `disconnect`).
- **Two seams** in the otherwise-shared UI: (a) **signing** branches on `backend`
  (§4.3); (b) **chain ops** branch on `chain` (§4.6). Everything else — address
  display, asset list, history — is keyed by account/address and is backend- and
  chain-agnostic via libwallet.

### 4.6 Multi-chain money layer — port to libwallet (D13)

**libwallet already provides balances/RPC/send/swap cross-chain** — the job is
replacing Tibane's Solana-only app code with libwallet's APIs (Ellipx is the
reference implementation), NOT writing chain cryptography:
- **Send** (`send_screen.dart`): build/sign/broadcast via libwallet
  `client.transactions` for the current account's chain instead of Solana-specific
  tx construction. Ellipx ref: `lib/screens/send/*`, `SharedWallet.signAndSend`.
- **Swap** (`swap_screen.dart`): Tibane uses Jupiter (Solana-only). libwallet's
  `client.swap.quotes()` (OKX) covers **Solana + EVM** — port Ellipx's swap onto
  it so swap works per chain.
- **Networks**: use `client.networks` (current network per chain) instead of the
  hard-coded Helius Solana constants where feasible.
- **Solana-only features stay Solana-gated**: **staking** (ChiefStaker program)
  and the **incinerator** (SPL burn) are Solana-specific — hide/disable them when
  the current account's chain isn't Solana (chain-capability gating).
- Address formats / explorer links / fee display: derive per chain
  (`accounts.addressFormats`, network metadata).

> **Scope note:** this is the largest part of the migration, but it is a **port
> onto libwallet's existing multi-chain APIs**, not new chain plumbing. It still
> touches send, swap, assets, networks, and the home UI — treat §4.6 as its own
> phase (see §7).

### 4.7 Current-account persistence & edge cases

- Persist the current-account pointer: `{backend, accountId | "mwa:"+address}`.
  In-app reuse `client.accounts.setCurrent(accountId)`; MWA stores a local flag +
  address.
- **Restart while MWA was current but now disconnected**: MWA can't be restored
  silently → fall back to the most recent **in-app** account (or empty state);
  selecting the MWA entry later triggers reconnect. Define this so the app never
  boots into a dead current account.
- **Current account's wallet/account removed**: pick the next available account
  (account-granular version of the existing `pickNextActive`).
- **No accounts at all**: empty state (§4.9).

### 4.8 2FA recovery entry point (lockless model)

Today 2FA device-share recovery is auto-triggered by the unlock screen when no
local device share exists. With the unlock screen gone, give recovery an explicit
home:
- A **"Recover device key (2FA)"** action on the wallet/account detail screen,
  reusing `startRemoteKeyReshare` + `recoverDeviceShareVia2fa`.
- Also trigger it on demand when a **sign attempt finds no usable StoreKey** on
  this device (the §3.2 fallback chain came up empty) — prompt to recover rather
  than failing silently.

### 4.9 Empty state + state management

- **Empty state**: no in-app wallet AND no MWA connected → the account switcher
  shows a "Create or connect a wallet" affordance (preserves D2
  browse-without-a-wallet). Home/Browse stay usable.
- **State management**: keep **Provider/ChangeNotifier** (do NOT port Ellipx's
  BLoC). Re-create the *concepts* (current account, account list, per-account
  assets) as `ChangeNotifier` state on `WalletService`.

### 4.10 Files to touch (Tibane)

- `lib/services/wallet_service.dart` — current-account model + persistence;
  unified account list (pure builder, §4.2); `setCurrentAccount`; per-account
  assets via libwallet (§4.4); façade `authorizeAndSign` / `signTransactions(ctx,…)`
  (§4.3); remove `WalletKind`-as-active-toggle.
- `lib/services/wallet/wallet_backend.dart` — change the signing interface to
  per-call authorization (the ripple center, §4.3).
- `lib/services/wallet/libwallet_backend.dart` — delete `unlock/lock/switchWallet`
  + `_signingKeys()` + session fields; per-tx sign via collected `SigningKey`s;
  expose accounts.
- `lib/services/wallet/mwa_wallet_backend.dart` — expose account/address + connect
  for the unified list; per-call sign.
- New widgets: the **sign sheet** (port Ellipx `dialog_wallet_keys_unlock` +
  `wallet_keys_unlock`); the **account switcher** + **add-account** UI (Ellipx
  `dropdown_accounts.dart`, `SharedAccount.createAccount`); the **2FA recovery**
  entry (§4.8).
- Assets: port `SharedAsset` / `AssetCubit`; drop `_solBalance`/`_chiefPussyBalance`
  + the `RpcService` balance scan; Home renders the asset list.
- Multi-chain (§4.6): `send_screen.dart`, `swap_screen.dart` → libwallet
  `transactions` / `swap` / `networks`; gate `staking/*` + `incinerator_screen.dart`
  to Solana accounts.
- Delete `inapp_unlock_screen.dart`; remove the biometric toggle + "Lock wallet"
  (§3.3).

### 4.11 Tests (Feature 1)

- Pure (`@visibleForTesting`): `buildUnifiedAccounts(...)`; current-account
  routing (→ backend + chain); persistence fallback (MWA-disconnected restart →
  in-app fallback); chain-capability gating (staking/incinerator hidden for
  non-Solana); required-signing-keys resolver from `threshold`;
  next-account-after-removal.
- Device-verify: switching accounts loads the right per-chain assets; in-app
  per-tx sign sheet (biometric + password); MWA sign; an EVM send + swap via
  libwallet; staking hidden on an EVM account.

### 4.12 ClawdWallet / agent wallets — kept separate (D14)

Agent wallets ("ClawdWallet") are a **Tibane-only** feature with no Ellipx
equivalent, and they are **deliberately excluded** from the account-centric model.

What they are (for context):
- An agent-controlled MPC wallet backed by phplatform `Crypto/WalletSign`
  (`Type='agent'`) with a spending **policy** (per-tx / daily USD caps, recipient
  allow/denylist) and a kill-switch. Solana-only.
  (`lib/services/clawdwallet_service.dart`, `lib/screens/clawdwallet/*`.)
- Key topology: agent share + wdrone (service signer) share + a **mobile share**.
  The phone is a **policy checkpoint, not a per-tx signer** — the user does NOT
  sign agent transactions, and there is **no biometric/password prompt** for them.
- Created via a pairing + form flow → `client.wallets.createAgentWallet` /
  `initiateKeygen` (`create_agent_wallet_screen.dart`,
  `wallet_api.dart:createAgentWallet`). The mobile keygen share is held by
  libwallet locally — **separate** from the StoreKey/RemoteKey/Password committee.

Why separate (decision rationale):
1. **Not libwallet `Wallet`s** — fetched from `Crypto/WalletSign` REST, absent from
   `client.wallets.list()` / `client.accounts.list()`, so they won't appear in the
   unified list automatically (and must not be added manually).
2. **Different signing model** — autonomous (agent + wdrone + policy); the §4.3
   per-tx Password+biometric sign sheet does **not** apply.
3. **Different lifecycle/UI** — opt-in power feature under Settings → Connections →
   "Agent wallets" (`AgentsScreen`), with lock/kill-switch + activity log.

Guardrails for this migration (do not break agent wallets):
- **Feature 1**: keep `ClawdWalletService` a **parallel** service; do NOT fold agent
  wallets into `UnifiedAccount` / the current-account model / the account switcher.
  (Optional, non-blocking: a separate "Agent wallets" summary line on the
  dashboard — clearly distinct from user accounts.)
- **Feature 3 (migration) + lock removal**: scope strictly to **normal in-app
  wallets** (iterate `client.wallets.list()` / StoreKey-bearing wallets). Agent
  wallets aren't in that list, but be explicit: **do NOT touch the agent mobile
  keygen share** in SecureKeystore, and removing `unlock/lock` must not disturb
  agent signing (it's autonomous, never depended on the app-level unlock).
- **Out of scope**: no biometric, no current-account, no per-tx sign-sheet changes
  for agent wallets. Leave the Agents UI as-is.

---

## 5. Feature 2 — Ellipx-style creation onboarding + enforce biometric

### 5.1 Scope (per D2, D5, D6)

- **Do not** force onboarding at launch (D2) — keep Home/Browse usable with no
  wallet. Only the **MPC creation flow** adopts Ellipx's steps + biometric
  enforcement.
- **MWA wallets: no change** (D6) — "add biometric to MWA" resolves to **nothing
  extra**. Drop this from scope beyond a note.

### 5.2 Ellipx creation flow to mirror

Ellipx setup state machine (`lib/screens/setup/setup.dart`, states:
`disclaimer → newUser → password → askMethod → phone/email → codeConfirmation →
creatingWallet → wallet`). Key steps to port into Tibane's
`lib/screens/wallet/inapp_create_screen.dart`:
1. **Biometric availability gate** (Ellipx `intro/intro.dart:_check`,
   `intro/biometric.dart`): on entering creation, check
   `local_auth`/`biometric_storage` availability.
   - available → proceed to the standard (biometric) creation.
   - **not available → D5 fallback**: create a no-StoreKey committee that the
     **password alone can sign**. Per S1 (§3.2) signing needs **2 shares** and
     RemoteKey can't sign (D9), so a plain `Password + RemoteKey` wallet would be
     **unsignable**. Use **multiple password-derived shares** so one typed
     password yields the 2 shares — e.g. **`[Password, Password, RemoteKey]`,
     threshold 1**: the password unlocks 2 shares to sign; RemoteKey stays for 2FA
     recovery. (This is Ellipx's "unsafe = 3× password" trick, plus a RemoteKey for
     recovery.) Verify `wallets.multiCreate` accepts duplicate-type keys; if not,
     fall back to `[Password, Password]` (no recovery factor). Label this path
     clearly as lower-security.
2. **Password** (≥ 8 chars, confirmed) + wallet name.
3. **2FA method** (email or SMS) → send → **OTP confirmation** →
   `remoteKeys.validate` returns the RemoteKey resource. (Tibane already does
   this in `inapp_create_screen.dart` — align the order/labels with Ellipx.)
4. **Creating wallet** (Ellipx `setup_creating_wallet.dart:_createWallet`):
   - if biometric: `storeKeys.create()` → **store the private key behind
     biometric** via `biometric_storage` (Ellipx `SharedWallet.generateStoreKey`
     → `Biometric.setSecuredKey`). This is the key behavioral change vs Tibane,
     which currently writes the device share to `flutter_secure_storage` no-auth.
   - build `keys`: `Password` (always) + `RemoteKey` (if present) + `StoreKey`
     (if biometric).
   - `wallets.multiCreate(name, keys)` → both curves (ed25519 + secp256k1).
   - create default accounts (Solana + Ethereum), `setCurrentAccount`.
   - **enforce biometric prompt** during `generateStoreKey` (Ellipx requires the
     biometric auth to succeed here; on cancel, error + retry).
5. Success → land on the account view.

### 5.3 Biometric enforcement detail

- "Enforce if available" (D5): if `local_auth` reports biometric available,
  the standard path **requires** a successful biometric enrollment of the
  StoreKey to finish creation (mirror Ellipx). If not available → D5 fallback
  committee.
- Capability check: Ellipx `Biometric.hasBiometric()` (`lib/service/biometric.dart`).

### 5.4 Files to touch (Tibane)

- `lib/screens/wallet/inapp_create_screen.dart` — restructure to the Ellipx step
  flow + biometric gate + StoreKey-behind-biometric.
- New `Biometric` service in Tibane (port Ellipx `lib/service/biometric.dart`):
  `hasBiometric()`, `setSecuredKey(priv, pubKeyAlias)`, `askSecuredKey(alias)`.
- `pubspec.yaml` — add `biometric_storage`, `local_auth`.
- `lib/screens/wallet/wallet_screen.dart` — the "create your wallet" gate stays
  (D2), but routes into the new flow.

### 5.5 Tests (Feature 2)

- Pure: committee-shape selector (`biometric available → [Store,Remote,Password]`;
  `not available → [Remote,Password]`), create-step state transitions.
- Device-verify: biometric prompt fires during creation; StoreKey is readable
  back only via biometric; no-biometric device produces the fallback committee.

---

## 6. Feature 3 — Migration of existing wallets / biometric / password

### 6.1 What exists today (the "from" state)

- In-app wallet metadata + active pointer in SharedPreferences
  (`libw_wallet_id`, `libw_address`, `libw_name`, key-id keys; see
  `libwallet_backend.dart` `_prefs*`).
- Device share (StoreKey private) in `flutter_secure_storage` **no-auth**
  (`secure_keystore.dart` `libw_device_share_<walletId>`) **plus** a
  password-encrypted fallback blob (`libw_device_share_blob_v1_<walletId>`).
- Optional **password cache** behind biometric (`libw_biometric_pw`) + the
  `libw_biometric_enabled` toggle + the `libw_biometric_authreq_v1` migration flag.

### 6.2 Target ("to" state)

- StoreKey private key stored **behind biometric** via `biometric_storage`
  (§3.1), keyed by the StoreKey's public key (Ellipx convention:
  `Biometric.setSecuredKey(priv, walletKey.key)`).
- No lock/unlock, no password cache, no biometric-unlock toggle (§3.3).
- Keep the `flutter_secure_storage` password-encrypted fallback blob as the
  **non-biometric recovery copy** (and the storage for D5 no-biometric wallets).
- Account-centric current pointer (§4).

### 6.3 Migration mechanism — **eager one-time screen** (D7)

On first launch after the update, if a pre-migration in-app wallet is detected
and not yet migrated (gate on a new pref, e.g. `libw_ellipx_migrated_v1`):
1. Show a **dedicated migration screen** explaining the security upgrade.
2. For each in-app wallet with a StoreKey:
   - Read the existing device-share private key from the **no-auth OS keystore**
     (`secure_keystore.readDeviceShare` — for the OS-keystore copy this needs **no
     password**; only the fallback blob path needs one). Prefer the no-password
     path so the screen doesn't have to ask for the password.
   - **Re-store it behind biometric** via `biometric_storage` (triggers a
     biometric prompt). **Verify the biometric read returns the same value
     before deleting** the old no-auth entry (copy #1) (zero-data-loss principle).
   - **Do NOT delete the password-encrypted blob (copy #2)** — per **D8** it is
     intentionally kept as the OS-restore-surviving recovery copy.
3. Delete the obsolete biometric **password** cache (`libw_biometric_pw`) and the
   `libw_biometric_enabled` toggle; the password is never lost (it's the user's).
   (Note: the short-lived "auth-upgrade" migration / reset-notice attempt
   — `_migrateBiometricToAuthRequired`, `biometricResetNotice` — was reverted and
   never shipped, so there is nothing to remove there.)
4. Establish the account-centric current pointer from the old active wallet.
5. Set `libw_ellipx_migrated_v1 = true` **only after** all wallets verified.
   If any step fails, do not set the flag and do not delete old data — retry next
   launch (idempotent).

Edge cases:
- **No biometric on the device:** can't move the StoreKey behind biometric. Keep
  the existing no-auth/fallback storage for that wallet and treat it like a D5
  `Password + 2FA`-style wallet (sign with password + 2FA / fallback). Document
  clearly; don't block the app.
- **Device share missing locally** (cross-device case): route to the existing 2FA
  recovery to re-mint a share, then store it behind biometric.
- **Multiple wallets:** iterate; per-wallet verify-before-delete.

### 6.4 Files to touch (Tibane)

- New migration screen + a `migrateToEllipxModelV1()` in `LibwalletBackend` (or a
  dedicated migrator), called from `TibaneShell`/`main.dart` startup (similar
  wiring to the current `biometricResetNotice` one-shot, but a full screen).
- `lib/services/wallet/secure_keystore.dart` — add the biometric (`biometric_storage`)
  path; **keep** the password-encrypted fallback blob (D8); reuse the existing
  verify-before-delete idiom from `migrateToPerWalletV2`.
- Remove the **original optional password-cache** code that gated the password
  behind biometric for app-level unlock: `libw_biometric_pw`
  (`writeBiometricPassword`/`readBiometricPassword`/`deleteBiometricPassword`),
  the `libw_biometric_enabled` toggle (`isBiometricEnabled`/`enableBiometricUnlock`/
  `disableBiometricUnlock`/`unlockWithBiometric`), and the Settings
  `_BiometricToggleTile`. (The `_androidBio`/`_iosBio` options and the
  `_migrateBiometricToAuthRequired`/`biometricResetNotice` experiment were already
  reverted — see git history — so they no longer exist to remove.)

### 6.5 Tests (Feature 3)

- Pure: migration decision (`shouldMigrate(alreadyMigrated, hasInappWallet,
  biometricAvailable)`), per-wallet plan builder.
- Integration (mock SharedPreferences + the catch-on-missing-plugin keystore
  pattern): the migration flag is one-shot and verify-before-delete holds (old
  entry only removed after the new one reads back).
- Device-verify: real biometric re-enrollment of the StoreKey; sign works after
  migration; no-biometric device keeps the fallback path.

---

## 7. Suggested phasing & order

Each phase is independently shippable with its own tests; device-validate before
committing.

1. **Phase 0 — Foundations:** add `biometric_storage` + `local_auth`; port the
   Ellipx `Biometric` service. (S1 is already resolved — §3.2 — so the signing UX
   is fixed: per-tx Password + biometric, 2-of-3.)
2. **Phase 1 — Per-transaction signing (in-app):** introduce the Ellipx-style
   sign sheet that collects Password + biometric StoreKey (`threshold + 1` shares)
   per transaction; keep the old unlock path in parallel behind a flag until proven.
3. **Phase 2 — Creation flow (Feature 2):** Ellipx-style creation + biometric
   enforcement + D5 fallback. New wallets are born in the target shape.
4. **Phase 3 — Migration (Feature 3):** eager one-time screen migrates existing
   wallets to biometric StoreKey; remove the password-cache/unlock-toggle code.
5. **Phase 4 — Account-centric core (Feature 1a):** the `UnifiedAccount` model
   (§4.2), unified account list + switcher + add-account, `setCurrentAccount`,
   current-account persistence + edge cases (§4.7), MWA connect entry (§4.5),
   empty state (§4.9). Per-account **assets via libwallet** replacing the bespoke
   SOL/ChiefPussy fields (§4.4). Remove lock/unlock + "Lock wallet"; route signing
   through the §4.3 contract. (Solana accounts only need to *work* end-to-end here;
   EVM accounts can appear but defer their money ops to 4b.)
6. **Phase 5 — Multi-chain money layer (Feature 1b, D13):** port send / swap /
   networks onto libwallet's multi-chain APIs (§4.6); chain-gate staking +
   incinerator to Solana. This is the largest phase — split per surface
   (send, then swap) if needed.
7. **Phase 6 — Cleanup:** delete `unlock/lock/switchWallet`, `inapp_unlock_screen`,
   `_signingKeys`, and dead `WalletKind`-as-active code; finish replacing all
   `isUnlocked`/`isConnected` gates with `canSign`/`hasCurrentAccount`.

> Rationale for order: foundations + signing first (everything depends on the
> biometric StoreKey + per-tx model); creation before migration (so new wallets
> are correct and the migration only handles legacy); account-centric core (4a)
> before the multi-chain money-layer port (4b), since 4b builds on the
> current-account + asset plumbing from 4a. 4a/4b are the largest changes and
> deliberately come after the smaller, self-contained Features 2–3.

---

## 8. Open questions / risks

- **Per-transaction password friction (accepted, not open):** because signing
  needs 2 shares (S1 resolved) and biometric-only is impossible, **every send
  requires a typed password + biometric** — same as Ellipx. This is more friction
  than Tibane's old "unlock once, sign many." Flagged so it's a conscious choice;
  the only way to soften it would be a custodial/session model, which contradicts
  "remove lock/unlock."
- **Two secure-storage libraries** coexisting (`biometric_storage` for the
  biometric StoreKey, `flutter_secure_storage` for the fallback). Keep roles
  crisply separated (§3.1).

### Resolved (kept for the record)
- **S1 (signing threshold)** → **RESOLVED from the Go source** (§3.2): signing
  needs `threshold + 1` shares (default 2-of-3); biometric-only is impossible.
  No throwaway test needed — `wltwallet/frost_test.go`, `join.go`, `promote.go`.
- **MWA account enumeration** → **D11**: explicit connect (§4.5). Refinement
  found in code: the MWA backend already persists `wallet_public_key` in prefs and
  restores it in `tryRestore`, so the external address *is* available offline —
  the list can show a "last external wallet — tap to reconnect" entry and
  reconnect when the user acts on it.
- **Cloud backup / recovery scope** → **D12**: out of scope now; new wallets
  recover via the kept password blob (**D8**) + existing 2FA reshare + device
  transfer. Ellipx-style iCloud/Drive backup (`ellipx/lib/utils/backup.dart`,
  `icloud_storage` / Google Drive) is a documented **follow-up**, not part of
  this migration.
- **"Not-yet-migrated" StoreKey reads** → documented in §3.2 (read fallback
  chain: `biometric_storage` → no-auth keystore → password blob).
- **ClawdWallet / agent wallets** → **D14** (§4.12): kept separate from the
  account-centric model; autonomous, not libwallet wallets, no biometric/per-tx
  sign; the migration must not touch their key material.
- **Localization** → **D15**: new screens use inline English literals (match
  Tibane, which is English-only with no `intl`/`AppLocalizations`). Adopting
  Ellipx's l10n framework is a separate app-wide follow-up, not part of this
  migration.

---

## 9. File reference map

### Tibane (this repo)
- `lib/services/wallet_service.dart` — dual backend, `WalletKind`, `active`,
  `kind` persistence, balances.
- `lib/services/wallet/libwallet_backend.dart` — create/unlock/lock/switchWallet/
  removeWallet/tryRestore, key shares, biometric password cache + auth-upgrade
  migration, `biometricResetNotice`.
- `lib/services/wallet/secure_keystore.dart` — per-wallet device share (schema
  v2), OS-keystore vs password-encrypted fallback, `_iosBio`/`_androidBio`
  options, `migrateToPerWalletV2` (verify-before-delete idiom to reuse).
- `lib/services/wallet/mwa_wallet_backend.dart` — external/Seed Vault backend.
- `lib/screens/wallet/inapp_create_screen.dart` — current creation flow.
- `lib/screens/wallet/inapp_unlock_screen.dart` — current unlock + 2FA recovery
  routing (to be replaced by a per-tx sign dialog).
- `lib/screens/wallet/wallets_management_screen.dart`,
  `wallet_details_screen.dart` — wallet list/detail (re-frame to accounts).
- `lib/screens/settings/security_privacy_screen.dart` — biometric toggle,
  password change, share rotations (toggle to be removed).
- `lib/screens/settings_screen.dart` — "Lock wallet"/"Disconnect"
  (`_confirmLockOrDisconnect`).
- `lib/main.dart` — `TibaneShell` startup wiring (where the migration screen +
  account switcher hook in).
- `lib/services/clawdwallet_service.dart`, `lib/screens/clawdwallet/*`
  (`create_agent_wallet_screen.dart`, `agents_screen.dart`, `activity_screen.dart`,
  `pairing_screen.dart`), `connections_screen.dart` — **agent wallets (D14)**;
  keep separate, leave untouched (§4.12).

### Ellipx (blueprint)
- `lib/service/libwallet_service.dart` — FFI client init.
- `lib/service/biometric.dart` — `hasBiometric`, `setSecuredKey`, `askSecuredKey`
  (port this).
- `lib/crypto/shared_wallet.dart` — `generateStoreKey`, `generateSetupWallets`
  (multiCreate), `reshare`, device-transfer wrappers.
- `lib/crypto/shared_account.dart` — `getAccounts`, `getCurrentAccount`,
  `setCurrentAccount`, `createAccount`.
- `lib/crypto/shared_remote_key.dart` — `sendPhoneNumber/sendEmail/validateOtp`.
- `lib/bloc/current_account_bloc.dart`, `account_bloc.dart`, `wallet_bloc.dart`,
  `asset_bloc.dart` — the account-centric state (re-create as ChangeNotifier).
- `lib/screens/home/widgets/dropdown_accounts.dart` — the all-accounts switcher.
- `lib/screens/intro/intro.dart`, `intro/biometric.dart` — biometric availability
  gate.
- `lib/screens/setup/setup.dart` + `setup_*.dart` — creation state machine;
  `setup_creating_wallet.dart` is the key keygen+biometric step.
- `lib/screens/wallet/widgets/wallet_keys/dialog_wallet_keys_unlock.dart`,
  `wallet_keys_unlock.dart` — per-transaction sign dialog + StoreKey biometric
  read + in-dialog cache (port this for signing).
- `lib/crypto/wallet_service.dart` — per-tx key collection + `threshold + 1`
  validation.
- `lib/screens/wallet/widgets/device_transfer/*`, `reshare_flow/*` — recovery
  flows for later parity.
- `lib/store/shared_preferences.dart` — `UserCheckState` flags model.

### libwallet
- `~/.pub-cache/hosted/pub.dev/libwallet-0.4.68/lib/src/models/wallet.dart:30` —
  `threshold` doc comment (see S1).
- `~/.pub-cache/hosted/pub.dev/libwallet-0.4.68/lib/src/api/wallet_api.dart` —
  `create`, `multiCreate`, `update`, `reshare`, device-transfer, etc.
- `libwallet/wltwallet/wallet.go:256` — default `Threshold: 1`; sign needs
  `Threshold+1` (see `wltwallet/frost_test.go`, `join.go`).

---

## 10. libwallet API quick-reference (verified present in 0.4.68)

All accessed via `LibwalletClient` getters (`client.<x>`). Confirmed in
`lib/src/client/libwallet_client.dart` + the per-API files. This is the surface
the migration leans on — no missing APIs.

**Accounts** (`client.accounts`, `account_api.dart`) — the account-centric core:
- `list({String? wallet}) → List<Account>` — all accounts (optionally per wallet)
- `getCurrent() → Account` (`get('@')`), `setCurrent(String id)` — current-account pointer
- `create({name, wallet, type, index}) → Account` — add-account (D10)
- `signTransaction(id, {transaction, keys}) → Uint8List` — per-tx sign (pass collected `SigningKey`s)
- `signAndSendTransaction(id, …) → String`, `signMessage(id, …) → SignedMessage`
- `nextAddress`, `allAddresses`, `addressFormats` — multi-chain address display

**Assets** (`client.assets`, `asset_api.dart`) — replaces bespoke balances (§4.4):
- `list({String? convert}) → List<Asset>` — balances for the current account
- `invalidateCache()`; balance push via `client.balanceChanges` stream

**Transactions** (`client.transactions`, `transaction_api.dart`) — multi-chain send (§4.6):
- `signAndSend(UnsignedTransaction) → Stream<ProgressOr<Transaction>>`,
  `signAndSendSimple(...)`, `simulate`, `validate`, `list`, `maxSendable`

**Swap** (`client.swap`, `swap_api.dart`) — Solana + EVM via OKX (§4.6):
- `availability()`, `quote({...})`, `quotes({...}) → List<QuoteAttempt>`,
  `maxSpendable`, `buildApproval`, `execute({...}) → SwapResult`

**Networks** (`client.networks`, `network_api.dart`) — per-chain RPC selection:
- current-network get/`setCurrent`, list (use instead of hard-coded Helius consts)

**Keys / wallets:**
- `client.storeKeys.create()` → StoreKey pair (private goes into `biometric_storage`)
- `client.remoteKeys.create({email|number}) / validate({session, code})` → 2FA / RemoteKey
- `client.wallets.create / multiCreate({name, keys}) / get / list / update / reshare`
- StoreKey-behind-biometric is an **app** concern (`biometric_storage`), NOT a
  libwallet API — libwallet only mints the key pair; the app stores the private.
