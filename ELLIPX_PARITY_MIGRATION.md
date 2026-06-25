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
| D4 | Signing model after removing lock/unlock | **Mirror Ellipx** (per-transaction). See §3.2 — Ellipx requires **Password + biometric StoreKey per signature**; resolve the threshold ambiguity before assuming biometric-alone. |
| D5 | MPC creation on a device **without** biometric | **Password + 2FA fallback** — create a no-StoreKey committee from `Password + RemoteKey`. NOT Ellipx's "3× same password unsafe" wallet, and not blocking. |
| D6 | "Add biometric" for **MWA / Seed Vault** wallets | **Nothing extra** — Seed Vault does its own auth; do not add an app-level biometric layer for MWA accounts. (This simplifies Feature 2's MWA scope to "no-op".) |
| D7 | Migration of existing in-app wallets | **Eager one-time screen** at first launch after the update that re-secures the StoreKey behind biometric. |
| D8 | Password-encrypted fallback blob (the device-share copy in SharedPreferences) | **KEEP it** — prioritize recovery. The blob stays as a local, OS-restore-surviving recovery copy. ⚠️ Consequence: password-alone can still reconstruct the device share, so **biometric is a UX/convenience gate, not a hard second factor** (see §3.1 "Security consequence"). This intentionally diverges from Ellipx, which keeps the StoreKey *only* behind biometric. |
| D9 | RemoteKey as a signing factor | **Keep recovery-only** — RemoteKey is NOT used to sign (matches both apps; signing = StoreKey + Password). Consequence: the no-biometric D5 fallback must be **password-signable** on its own — see §5.2 + OPEN ITEM S1. |
| D10 | Account creation in the account-centric model | **Support add-account** — provide an "add account" flow (Ellipx `SharedAccount.createAccount`) so the unified list can grow (more chains / multiple accounts per wallet). |
| D11 | How the external MWA/Seed Vault account enters the unified list | **Explicit connect** — keep an MWA "connect" action; the external account appears in the list **only while connected** (MWA can't enumerate offline). Resolves the §4.2 open question. |
| D12 | Cloud backup / recovery scope for this migration | **Out of scope now** — new wallets recover via the kept password blob (D8) + existing 2FA reshare + device transfer. Ellipx-style iCloud/Drive backup is a later follow-up. |

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

**There is a real contradiction** between the doc comment ("min to sign = threshold
= 1", i.e. 1 share could sign) and Ellipx's `threshold + 1` collection (2 shares).
This must be resolved empirically before finalizing the signing UX:

- **OPEN ITEM S1 — verify with libwallet:** does `accounts.signTransaction` /
  `signAndSend` actually succeed with **1** share when `threshold == 1`, or does
  it require 2? Write a throwaway test against libwallet.
  - If **1 share signs** → we can offer **biometric-only signing** (StoreKey
    alone), which is far smoother and matches the product owner's stated lean
    ("if none, 1"). **Prefer this if it works.**
  - If **2 shares are required** → mirror Ellipx exactly: **Password + biometric
    per transaction**. Faithful but higher friction than Tibane's current
    "unlock once, sign many."
- **Default for the doc until S1 is resolved:** implement the per-transaction
  unlock dialog (Ellipx parity: Password + StoreKey-biometric), with the StoreKey
  cached only within the dialog session. Structure the code so switching to
  biometric-only is a one-line threshold/collection change if S1 says 1 share is
  enough.

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
  - then **load balances for that account's address** (balances are by address
    via RPC, so the existing `WalletService.refreshBalances()` works for both).
- **No lock/unlock** (see §3.3). Nothing is "unlocked"; the current account just
  determines which backend signs and (for in-app) which wallet's shares to
  collect per transaction.
- **Add-account (D10).** Provide an "add account" flow so the unified list can
  grow — additional chains and/or multiple accounts per in-app wallet. Port
  Ellipx `SharedAccount.createAccount(walletId, name, type)`
  (`lib/crypto/shared_account.dart`); the account-add UI lives near the account
  switcher. (MWA accounts are added by connecting, per D11, not via this flow.)

### 4.2 Dual-backend reconciliation — the hard part (investigate first)

The product owner wants both backends in one list "if possible." Known frictions
to resolve during implementation:
- **MWA account enumeration — RESOLVED (D11): explicit connect.** Seed Vault/MWA
  exposes only the *currently authorized* account, and only while a connection is
  live — it can't enumerate offline. Per D11, keep an MWA **"connect"** action;
  once authorized, the external account appears in the unified list and is
  selectable, and it is **only shown while connected**. Check
  `lib/services/wallet/mwa_wallet_backend.dart` for `connect`/`publicKey`/
  `disconnect` and wire the connect entry point into the account switcher.
- **Signing divergence.** In-app accounts → per-tx Password + biometric StoreKey
  (§3.2). MWA accounts → Seed Vault's own auth, **no app-level biometric** (D6).
  The send/sign flows must branch on the current account's backend.
- **Shared UI.** The send screen, receive/address display, balances, and history
  should be backend-agnostic (keyed by address). Only the *signing step* differs.
  Aim for one UI with a backend-strategy seam at signing.
- **`kind` persistence.** Today `WalletService._kind` is persisted
  (`wallet_service.dart`). Replace with a persisted **current-account pointer**
  (account id + a flag for "MWA current"). For in-app accounts reuse
  `client.accounts.setCurrent`.

### 4.3 State management note

Tibane uses **Provider/ChangeNotifier**, Ellipx uses **BLoC/Cubit**. Do **not**
rewrite to BLoC — keep Provider. Re-create Ellipx's *concepts* (current account,
account list, balances-follow-current-account) as `ChangeNotifier` state on
`WalletService`, not its Cubit classes.

### 4.4 Files to touch (Tibane)

- `lib/services/wallet_service.dart` — replace `WalletKind`-as-active-toggle with
  a **current-account** model; unified account list; `setCurrentAccount`;
  balances follow current account; route signing per current account's backend.
- `lib/services/wallet/libwallet_backend.dart` — remove `unlock/lock/switchWallet`
  session model; add per-account current-account handling; expose account list;
  per-tx signing that biometric-reads the StoreKey.
- `lib/services/wallet/mwa_wallet_backend.dart` — expose its account(s)/address
  for the unified list.
- `lib/screens/home_screen.dart`, `lib/main.dart` (`TibaneShell`) — account
  switcher UI (dropdown of all accounts, Ellipx `dropdown_accounts.dart`).
- `lib/screens/wallet/wallets_management_screen.dart`,
  `wallet_details_screen.dart` — re-frame around accounts; the wallet still
  exists as a grouping, but the user switches **accounts**.
- `lib/screens/wallet/inapp_unlock_screen.dart` — delete/replace with a
  per-transaction sign dialog (port Ellipx `dialog_wallet_keys_unlock.dart` +
  `wallet_keys_unlock.dart`).
- `lib/screens/settings/security_privacy_screen.dart` — remove the biometric
  unlock toggle; remove "Lock wallet".
- Send/sign flows (`lib/screens/wallet/send_screen.dart`, swap, staking,
  incinerator) — call the new per-tx sign dialog instead of `ensureUnlocked`.

### 4.5 Tests (Feature 1)

- Pure: unified-account-list builder (given in-app accounts + MWA account →
  ordered list), current-account routing (account → backend), balances-target
  resolver. Follow the existing `@visibleForTesting` static-decision pattern
  (`pickNextActive`, `walletDetailActions`).
- Device-verify: the dropdown switch loads correct balances for both an in-app
  and an MWA account; signing routes correctly per backend.

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
   - **not available → D5 fallback**: create a no-StoreKey committee. ⚠️ Because
     **RemoteKey is recovery-only (D9)** and isn't a signer, the fallback must be
     **password-signable on its own**. Resolve via **S1**: if libwallet signs with
     1 share, a `Password + RemoteKey` committee where the Password alone meets
     the sign threshold works (RemoteKey stays a recovery factor). If 2 shares are
     required and RemoteKey can't sign, the fallback must instead be a
     **password-only (1-of-1)** wallet. Implement as a distinct, clearly-labeled
     path (NOT Ellipx's "3× same password unsafe").
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
   Ellipx `Biometric` service; **resolve OPEN ITEM S1** (does libwallet sign with
   1 share at threshold 1?). The answer sets the signing UX for all later phases.
2. **Phase 1 — Per-transaction signing (in-app):** introduce the Ellipx-style
   sign dialog reading the StoreKey via biometric; keep the old unlock path in
   parallel behind a flag until proven.
3. **Phase 2 — Creation flow (Feature 2):** Ellipx-style creation + biometric
   enforcement + D5 fallback. New wallets are born in the target shape.
4. **Phase 3 — Migration (Feature 3):** eager one-time screen migrates existing
   wallets to biometric StoreKey; remove the password-cache/unlock-toggle code.
5. **Phase 4 — Account-centric model (Feature 1):** unified account list +
   `setCurrentAccount` + balances-follow-account; remove lock/unlock + "Lock
   wallet"; reconcile the dual backend (§4.2).
6. **Phase 5 — Cleanup:** delete `unlock/lock/switchWallet`, the unlock screen,
   and dead `WalletKind`-as-active code; update all `isUnlocked`/`isConnected`
   gates.

> Rationale for order: foundations + signing first (everything depends on the
> biometric StoreKey + per-tx model); creation before migration (so new wallets
> are correct and the migration only handles legacy); account-centric last (the
> largest UI change, and it builds on the lockless signing).

---

## 8. Open questions / risks

- **S1 (critical):** does libwallet sign with **1** share at `threshold == 1`, or
  is Ellipx's `threshold + 1` (2 shares) actually required? Determines
  biometric-only vs Password+biometric per transaction (§3.2). **Verify before
  Phase 1.**
- **Per-transaction password friction:** if S1 says 2 shares, every send needs a
  typed password + biometric. Confirm the product owner accepts this (Ellipx
  does) or wants the biometric-only path (requires S1 == 1 share, or a threshold
  change at creation).
- **Two secure-storage libraries** coexisting (`biometric_storage` for the
  biometric StoreKey, `flutter_secure_storage` for the fallback). Keep roles
  crisply separated (§3.1).
- **ClawdWallet (agent wallets):** Tibane has agent/ClawdWallet flows
  (`lib/screens/clawdwallet/*`, `create_agent_wallet_screen.dart`,
  `services/clawdwallet_service.dart`). They were **not** covered by D1–D12 —
  verify how agent wallets fit the account-centric model (do their accounts join
  the unified list? do they need biometric?) before Phase 4.
- **Localization / strings:** the new migration, creation, and sign-dialog
  screens need user-facing strings. Tibane inlines strings (no `AppLocalizations`
  like Ellipx) — keep that style unless a decision says otherwise.

### Resolved (kept for the record)
- **MWA account enumeration** → **D11**: explicit connect; the external account
  shows only while connected (§4.2).
- **Cloud backup / recovery scope** → **D12**: out of scope now; new wallets
  recover via the kept password blob (**D8**) + existing 2FA reshare + device
  transfer. Ellipx-style iCloud/Drive backup (`ellipx/lib/utils/backup.dart`,
  `icloud_storage` / Google Drive) is a documented **follow-up**, not part of
  this migration.
- **"Not-yet-migrated" StoreKey reads** → documented in §3.2 (read fallback
  chain: `biometric_storage` → no-auth keystore → password blob).

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
- `libwallet/wltwallet/wallet.go:256` — default `Threshold: 1` (if Go source
  present).
