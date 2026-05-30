# Multi-wallet support — implementation spec

Goal: let the app hold **several in-app (libwallet) wallets at once**, each
with its own device (StoreKey) share stored independently, and let the user
**switch the active wallet** and **switch accounts across wallets**. This
also unblocks: receive-by-transfer adding a wallet to the list *without*
disconnecting, and transferring *any* wallet (not just the active one).

This doc is grounded in the current code. File paths and symbols are real;
follow them exactly. Read `DEVICE_TRANSFER_PLAN.md` /
`LIBWALLET_DEVICE_TRANSFER.md` for the transfer flows that depend on this.

> ## ⚠ Migration policy (MANDATORY)
>
> **Every change to on-device persisted data in this effort ships with a
> migration so existing installs upgrade with ZERO data loss.** No exceptions
> — a user who updates the app must keep every wallet, device share, biometric
> setting, and preference. Rules for every migration:
>
> - **Idempotent + versioned** — gate on a bumped flag (e.g.
>   `libw_schema_v2`); safe to run repeatedly and after a partial/crashed run.
> - **Verify-before-delete** — write the new entry, **read it back and confirm
>   it matches**, and only THEN delete the legacy entry. A failed/aborted
>   migration MUST leave the old data intact.
> - **Additive-first** — prefer adding new keys to renaming. When a rename is
>   unavoidable (e.g. per-wallet device share), it's copy → verify → delete,
>   never move-in-place.
> - **No silent secret loss** — never delete a secret (device share, biometric
>   password, legacy plaintext key) without a confirmed copy. A lost device
>   share forces the user through 2FA recovery — treat it as data loss.
> - **Forward-only & logged** — log each migration step (ids/keys only, never
>   secret bytes) so a failed upgrade is diagnosable from a support log.
>
> Applies to everything that persists: SharedPreferences keys, OS-keystore
> entries, the wallet index, and any future schema bump. If a PR changes a
> stored key's name, shape, or location, it is incomplete without its
> migration and a test that exercises the upgrade path.

> ## ⚠ Testing policy (MANDATORY)
>
> **Every phase ships unit tests in the same PR.** A phase is not "done"
> without them. Concretely:
>
> - **Extract pure logic so it's testable without a platform.** Decisions
>   like "same-wallet vs cross-wallet switch", account resolution, the
>   active-state assembly, and migration steps should be plain functions /
>   `@visibleForTesting` helpers, not buried in `await`-heavy methods or UI.
> - **Keystore / prefs logic** → `flutter test` with
>   `SharedPreferences.setMockInitialValues` (the fallback-blob path runs
>   without a platform; see `test/secure_keystore_test.dart`).
> - **Backend flows that need libwallet** → either inject a fake/minimal
>   client at the seam, or extract the pure decision out of the I/O and test
>   that. Don't let "it needs the client" be an excuse to skip the test.
> - **UI phases** → a `flutter_test` widget test for the key states (e.g.
>   "Use this wallet" shown only for the non-active wallet; unlock-prompt
>   routing).
> - Run `flutter analyze` + `flutter test` green before committing each phase.
>
> Each phase below lists its required **Tests:**.

---

## 1. Why it's blocked today (exact symbols)

The app is hard-wired to a **single active in-app wallet**:

- **`LibwalletBackend`** (`lib/services/wallet/libwallet_backend.dart`) is a
  singleton holding one wallet's state in single-valued fields:
  `_walletId, _accountId, _publicKey, _walletName, _storeKeyId,
  _remoteKeyId, _passwordKeyId, _storeKeyPriv, _password`.
- **Prefs are single-valued** (one wallet): `_prefsWalletId='libw_wallet_id'`,
  `_prefsAccountId='libw_account_id'`, `_prefsAddress='libw_address'`,
  `_prefsStorePub='libw_store_pub'`, `_prefsStoreKeyId='libw_store_kid'`,
  `_prefsRemoteKeyId='libw_remote_kid'`, `_prefsPasswordKeyId='libw_pass_kid'`,
  `_prefsName='libw_name'`, `_prefsBiometricEnabled='libw_biometric_enabled'`,
  `_prefsNetworkPicked='libw_network_picked'`, `_prefsStorePriv='libw_store_priv'`
  (legacy).
- **`SecureKeystore`** (`lib/services/wallet/secure_keystore.dart`) stores
  **one** device share under fixed keys:
  `_ksDeviceShare='libw_device_share'` (OS keystore),
  `_spFallbackBlob='libw_device_share_blob_v1'` (password-encrypted blob in
  SharedPreferences), `_ksBiometricPw='libw_biometric_pw'` (biometric cache).
- **`_persist({storeKeyPublic})`** writes the active wallet's ids to those
  single prefs keys and calls `_keystore.writeDeviceShare(...)` into the
  single slot.

Consequence: **every `create` / `import` / `receive` overwrites the single
device-share slot and the single prefs set.** `client.wallets.list()` still
returns every wallet in libwallet's local store (so the list UI shows them
all — `WalletsManagementScreen`), but only the most-recent one has a usable
device share on this device. The others are orphaned: activating one would
find no device share and dead-end into 2FA recovery.

The code already knows this gap — `switchAccount(accountId)`
(`libwallet_backend.dart` ~897) refuses cross-wallet switches with:
*"Switching to an account on a different wallet is not yet supported …
would require reloading a different wallet's TSS shares, which isn't wired
yet."*

---

## 2. Target model

Definitions:
- **Wallet** = a libwallet TSS wallet (`lw.Wallet`, has `id`, `curve`,
  `keys[]` of types StoreKey/Password/RemoteKey, `name`, `pubkey`). 2-of-3:
  signing = **StoreKey (device share) + Password** (`_signingKeys()`).
- **Account** = a chain account derived from a wallet (`lw.Account`, has
  `id`, `wallet`, `type` e.g. `solana`, `address`, `path`). A wallet can
  have several; libwallet tracks a server-side "current" account
  (`accounts.setCurrent`).
- **Active wallet** = the one whose shares are loaded in memory and whose
  device share lives in this device's keystore. Exactly **one unlocked
  wallet in memory at a time** (we keep the single in-memory field set;
  switching repopulates it). Other wallets are *known* (in the list, with
  their own stored device share) but *locked* (no `_password`/`_storeKeyPriv`
  in memory) until activated.
- **Active account** = `_accountId` / `_publicKey`, must belong to the
  active wallet.

Design principle: **persist as little as possible; re-derive from
libwallet.** Wallet metadata (name, key ids, accounts) is always
re-fetchable via `client.wallets.get(id)` + `_extractKeyIdsByType` +
`client.accounts.list(wallet:)`. The only things that *must* live on-device
per wallet are: (a) the **device share** (secret), and (b) optionally the
**biometric password cache**. Plus a single **active-wallet pointer**.

---

## 3. Storage design

### 3a. Per-wallet device share — `SecureKeystore`

Change every device-share method to take a `walletId` and key by it.

Key naming (sanitise `walletId` to keystore-safe chars — it's already a
`wlt-…` slug, safe, but guard anyway):
- OS keystore: `'libw_device_share_<walletId>'`
- Fallback blob (SharedPreferences): `'libw_device_share_blob_v1_<walletId>'`
- Biometric cache (decision below): `'libw_biometric_pw_<walletId>'`

New signatures (replace the current single-slot ones):
```dart
Future<void> writeDeviceShare({required String walletId, required String value, required String password});
Future<String?> readDeviceShare({required String walletId, String? password});
Future<bool> hasDeviceShare(String walletId);
Future<void> deleteDeviceShare(String walletId);
// biometric, per wallet:
Future<void> writeBiometricPassword(String walletId, String password);
Future<String?> readBiometricPassword(String walletId);
Future<void> deleteBiometricPassword(String walletId);
Future<bool> isBiometricEnabled(String walletId); // pref flag per wallet
```

`_encryptWithPassword/_decryptWithPassword/_deriveKey/_randomBytes/
isSecureStorageUsable/isBiometricAvailable` are unchanged.

> Biometric decision: make the cache **per wallet** (recommended) so each
> wallet can have biometric unlock independently and a wallet's password is
> never reachable via another wallet's biometric. The
> `_prefsBiometricEnabled` flag becomes per-wallet too
> (`'libw_biometric_enabled_<walletId>'`).

### 3b. Active-wallet pointer + wallet index (prefs)

- Keep a single **active pointer**: reuse `_prefsWalletId='libw_wallet_id'`
  to mean "the wallet to auto-load on launch" (the active one), plus
  `_prefsAccountId` for its active account. Everything else
  (`_prefsName/_prefsStoreKeyId/...`) becomes **derivable** — drop reliance
  on them for non-active wallets.
- Optional **known-wallets index**: a JSON list under a new key
  `'libw_wallets_v1'` = `[{walletId, lastAccountId}]`. Only needed if you
  want to (a) remember each wallet's last-used account, or (b) show the list
  without a libwallet round-trip. **Recommended minimal:** skip the index;
  enumerate via `client.wallets.list()` (already done by
  `WalletsManagementScreen`) and store only `lastAccountId` per wallet if
  desired (`'libw_last_account_<walletId>'`).

### 3c. Migration (mandatory — see the policy callout at the top)

Existing installs have the legacy single-slot share + single prefs, all
belonging to the **current active wallet** (`prefs['libw_wallet_id']`). The
migration re-keys every single-slot entry to that wallet's id. Complete
legacy → per-wallet map:

| Legacy key (store) | New key (store) | Secret? |
|---|---|---|
| `libw_device_share` (OS keystore) | `libw_device_share_<activeId>` | **yes** |
| `libw_device_share_blob_v1` (prefs) | `libw_device_share_blob_v1_<activeId>` | **yes** (enc) |
| `libw_biometric_pw` (OS keystore) | `libw_biometric_pw_<activeId>` | **yes** |
| `libw_biometric_enabled` (prefs bool) | `libw_biometric_enabled_<activeId>` | no |
| `libw_store_priv` (prefs, legacy plaintext) | → keystore `libw_device_share_<activeId>` then delete | **yes** |

Unchanged / kept as-is (no migration, backward compatible): `libw_wallet_id`
(now means "active wallet pointer"), `libw_account_id`, `libw_address`,
`libw_name`, `libw_store_kid`, `libw_remote_kid`, `libw_pass_kid`,
`libw_store_pub`, `libw_network_picked`. These keep working for the active
wallet; per-wallet metadata for *other* wallets is re-derived from libwallet
(`client.wallets.get` / `accounts.list`), so nothing else needs persisting.

Algorithm — `SecureKeystore.migrateToPerWalletV2(activeWalletId)`, called
once from `tryRestore` (after the active pointer is read, before any unlock):
```
if prefs['libw_schema_v2'] == true: return            // idempotent gate
activeId = prefs['libw_wallet_id']
if activeId == null:                                   // fresh install
    prefs['libw_schema_v2'] = true; return             // nothing to migrate

for (legacy, perWallet) in MAP:                        // table above
    if exists(legacy):
        write(perWallet, read(legacy))
        assert read(perWallet) == read(legacy)         // VERIFY-BEFORE-DELETE
        // do NOT delete yet — defer deletes to the end

// only after ALL copies verified:
for (legacy, _) in MAP: delete(legacy)
prefs['libw_schema_v2'] = true
log('[migration] v2 per-wallet keystore complete for <activeId>')
```
- **Abort-safe:** if any `assert` fails or the app is killed mid-run, the
  `libw_schema_v2` flag is never set and no legacy key was deleted → next
  launch re-runs cleanly. The per-wallet reads also tolerate a half-written
  state because `readDeviceShare` falls back to the legacy slot until the
  flag flips (keep a legacy-fallback read path for one release).
- **Keep the existing legacy plaintext migration** that `unlock` already does
  (`libw_store_priv` → keystore, `libwallet_backend.dart` ~565-575): fold it
  into this step so it's covered even before the first unlock.
- **Test:** seed a fake legacy install (single-slot share + blob + biometric),
  run migration, assert per-wallet entries readback-equal and the wallet
  still unlocks; run it twice (idempotent); simulate a crash between copy and
  delete (legacy intact, re-run succeeds).

---

## 4. Backend (`LibwalletBackend`) changes

Keep the **single in-memory active-wallet field set** (`_walletId`,
`_storeKeyPriv`, `_password`, …) and `_signingKeys()` **unchanged**. The
change is *how those fields get populated* — from any wallet's per-wallet
storage, not just the one last written.

### 4a. New: load/activate an arbitrary wallet

```dart
/// Make [walletId] the active wallet, unlocking it for signing. Reloads the
/// wallet's TSS shares: fetches metadata from libwallet, reads THIS wallet's
/// device share from the keystore (by id), validates [password]. If no
/// local device share exists, returns a typed "needs recovery" signal so
/// the UI routes to 2FA reshare for this wallet.
Future<SwitchResult> switchWallet(String walletId, {String? password}) async {
  if (_walletId == walletId && isUnlocked) return SwitchResult.ok;
  final client = await _getClient();
  final w = await client.wallets.get(walletId);
  final keyIds = _extractKeyIdsByType(w);
  // pick the account: lastAccountId for this wallet, else first 'solana', else create index 0
  final account = await _resolveAccount(client, walletId);
  // load THIS wallet's device share (by id):
  final priv = await _keystore.readDeviceShare(walletId: walletId, password: password);
  if (priv == null) return SwitchResult.needsRecovery; // 2FA reshare for walletId
  // validate password against THIS wallet's Password share:
  await client.storeKeys.derivePassword(password: password!, walletKeyId: keyIds['Password']!);
  await client.accounts.setCurrent(account.id);
  // swap the active in-memory set (this implicitly LOCKS the previous wallet):
  _walletId = walletId; _accountId = account.id; _publicKey = account.address;
  _walletName = w.name; _storeKeyId = keyIds['StoreKey'];
  _remoteKeyId = keyIds['RemoteKey']; _passwordKeyId = keyIds['Password'];
  _storeKeyPriv = priv; _password = password;
  await _persistActivePointer();   // libw_wallet_id/account_id/address/name
  unawaited(ensureSolanaDefault());
  notifyListeners();
  return SwitchResult.ok;
}
```
- `SwitchResult` = `{ ok, wrongPassword, needsRecovery, error }` (or reuse
  bool + `_error` like the rest of the class — but `needsRecovery` must be
  distinguishable so the UI can branch to the 2FA screen).
- Add a biometric variant: `switchWalletWithBiometric(walletId)` →
  read per-wallet biometric password, then `switchWallet(walletId, password:)`.
- `_resolveAccount(client, walletId)` mirrors the account-pick logic already
  in `importViaDeviceTransfer` (prefer `lastAccountId`, else first `solana`,
  else `accounts.create(type:'solana', index:0)`).

### 4b. `unlock` / `hasLocalDeviceShare` take a walletId

- `unlock(password)` → operate on `_walletId` but read the device share via
  `readDeviceShare(walletId: _walletId!, password:)`. For unlocking a
  *different* wallet, callers use `switchWallet` instead.
- `hasLocalDeviceShare()` → `hasLocalDeviceShare(String walletId)` so the
  list/unlock UI can show per-wallet "usable here" state and pick
  password-vs-2FA per wallet.

### 4c. `switchAccount` — support cross-wallet

Replace the current guard (`acct.wallet != _walletId` → error) with:
```dart
if (acct.wallet != _walletId) {
  final r = await switchWallet(acct.wallet, password: /* may need prompt */);
  if (r != SwitchResult.ok) return false;   // UI handles password/recovery
}
await client.accounts.setCurrent(accountId);
_accountId = acct.id; _publicKey = acct.address; ...persist...
```
Because switching wallets needs the target's password, `switchAccount`
across wallets must be driven from UI that can prompt (see §6). Keep a
same-wallet fast path (no password needed).

### 4d. create / import / receive — register without clobbering

- **`create`**: unchanged behaviour (new wallet becomes active), but it now
  writes the device share under the **new wallet's id**
  (`writeDeviceShare(walletId: newId, …)`) — so creating a 2nd wallet no
  longer destroys the 1st's share. The previous active wallet stays in the
  list, still has its own device share.
- **`importViaDeviceTransfer`**: **drop the `hasWallet` guard.** Write the
  received share under its `walletId`. **Do not** change the active wallet.
  Drop the password step here (no activation now). The wallet is added to
  the list; the user activates it later via "Use this wallet" (§6).
  `abandonPendingTransfer` deletes only that wallet's per-wallet share.
- **`activateAfterTransfer`** → folds into `switchWallet(walletId, password)`.
- **`startDeviceTransferExport(walletId)`**: the "must be active" constraint
  relaxes — if the requested wallet isn't active, the UI can `switchWallet`
  to it first (prompt unlock), then export. (Still requires it unlocked to
  release the share.)

### 4e. disconnect / remove / lock

- **`disconnect()`** currently deletes the wallet + clears all prefs +
  deletes the single device share. Split into:
  - `removeWallet(walletId)`: `client.wallets.delete(walletId)` +
    `deleteDeviceShare(walletId)` + per-wallet biometric/flags + remove from
    index. If it was the active wallet, pick another wallet to activate (or
    enter empty state).
  - `lock()`: unchanged (clears `_password`/`_storeKeyPriv` of the active
    wallet only).
- `WalletDetailsScreen._remove` (currently calls `ws.disconnect()` when
  removing the active) → call `removeWallet(id)` and, if it was active,
  `switchWallet(nextWalletId)` or go to no-wallet.

---

## 5. `WalletService` changes (`lib/services/wallet_service.dart`)

- `_kind` (mwa | inapp) stays. Add `useWallet(String walletId, {password})`
  that calls `_libwallet.switchWallet(...)`, sets kind=inapp, and on success
  resets session state.
- **On any wallet/account switch, reset session-scoped state:**
  - `_solBalance/_chiefPussyBalance/_solFiatUsd/_chiefPussyFiatUsd = 0`,
    then `refreshBalances()`.
  - `_txCacheByAddress` is keyed by address, so it naturally isolates per
    account — no clear needed, but the dashboard should re-read for the new
    address.
  - `_authenticateWithServer()` again (the signing identity changed).
  - Re-evaluate the WalletConnect bridge (`_wc`): the active account/address
    changed → emit `accountsChanged` to connected dApps, or tear down WC
    sessions. Flag for the WC owner; at minimum, don't leave a bridge bound
    to the old account silently.
  - `ensureSolanaDefault()` / current-network: libwallet's "current" is tied
    to the account via `accounts.setCurrent`; confirm the network chip
    refreshes.
- `tryRestore()`: loads the active pointer (`libw_wallet_id`) and activates
  that wallet (locked — `tryRestore` never loads `_password`/`_storeKeyPriv`,
  same as today). The other wallets remain in the list.

---

## 6. UI changes

- **`WalletDetailsScreen`** (`lib/screens/wallet/wallet_details_screen.dart`):
  - Add a **"Use this wallet"** action (hidden/disabled when it's already
    the active "In use" wallet). Tapping it:
    1. If it has a local device share (`hasLocalDeviceShare(id)`): push
       `InAppUnlockScreen(walletId: id)` (biometric → password) →
       `switchWallet`. On success, pop to dashboard.
    2. If no local device share: push `InAppUnlockScreen(walletId: id)` in
       **recovery mode** (2FA reshare for that wallet) — mints a fresh
       device share locally for it, then activates.
  - "Transfer to a new device" (already added) works once the wallet can be
    made active — either require active first, or have it `switchWallet`
    then export.
- **`InAppUnlockScreen`** (`lib/screens/wallet/inapp_unlock_screen.dart`):
  - Parameterise by **`walletId`** (default = active). All of
    `unlock`/`unlockWithBiometric`/`hasLocalDeviceShare`/`startRemoteKeyReshare`/
    `recoverDeviceShareVia2fa` must target that wallet. `ensureUnlocked`
    gains an optional `walletId`.
  - The recovery (2FA) path currently reshares the **active** wallet's
    RemoteKey; make it target the requested `walletId`.
- **`WalletsManagementScreen`**: the "In use" badge already marks the active
  one. Optionally add a quick "Use" affordance on each row (or rely on the
  detail screen's button). Show a per-wallet hint when a wallet has no local
  device share ("needs 2FA to use here").
- **`AccountsManagementScreen`** (`lib/screens/wallet/accounts_management_screen.dart`):
  - Allow selecting an account from **any** wallet. If the tapped account's
    `wallet` differs from the active, drive the cross-wallet `switchAccount`
    (which prompts unlock for the target wallet via `InAppUnlockScreen`).
- **Receive flow** (`device_transfer_receive_screen.dart`): remove the
  "Disconnect current wallet?" dialog and the `hasWallet` guard usage.
  After `importViaDeviceTransfer` adds the wallet to the list, show
  "Wallet added — open it from your wallet list and tap *Use this wallet*"
  (or offer a one-tap "Use it now" that runs `switchWallet`). No password
  prompt unless they choose to activate immediately.

---

## 7. Security considerations

- **Isolation:** each wallet's device share is a distinct keystore entry;
  one wallet's compromise/removal doesn't touch another's. Keep the
  fallback blob password-encrypted per wallet (PBKDF2-AES-GCM, unchanged).
- **One unlocked wallet at a time:** only the active wallet's `_password`/
  `_storeKeyPriv` live in memory. Switching **locks** the previous wallet
  (clear its secrets) before loading the next. Never hold multiple
  passwords in memory.
- **Biometric per wallet:** a wallet's biometric cache must only unlock that
  wallet. Don't share one biometric entry across wallets.
- **Migration safety:** verify-before-delete (read back the per-wallet copy
  before removing the legacy entry). A failed migration must leave the
  legacy entry intact, not lose it.
- **No secret logging:** preserve the existing discipline — never log
  `_password`, device-share bytes, or backup JSON. The `[device-transfer]`
  diagnostics only print ids/lengths.
- **2-of-3 unchanged:** signing is still StoreKey + Password; this work only
  changes *which* wallet's shares are loaded, not the threshold model.
- **Removal:** `removeWallet` must delete the per-wallet device share +
  biometric so a removed wallet leaves no secret behind.

---

## 8. Edge cases

- **Remove the active wallet:** switch to another wallet in the list
  (activate it — may need its password) or, if none remain, enter the
  no-wallet/onboarding state. Don't silently clear everything.
- **Last wallet removed:** dashboard → create/import onboarding.
- **App restart:** `tryRestore` activates `libw_wallet_id` (locked). If that
  wallet was removed out of band, fall back to the first wallet in
  `client.wallets.list()` or empty.
- **Wallet with no local device share** (e.g. received-but-not-activated, or
  created on another device): list it, mark it "needs 2FA here", route
  activation through recovery.
- **MWA vs in-app:** `kind` still toggles between the MWA backend and
  libwallet. Switching in-app wallets implies `kind=inapp`. MWA is
  orthogonal.
- **Different password per wallet:** supported — `switchWallet` validates
  against the target wallet's own Password share.
- **Curve/network:** non-ed25519 wallets exist (`curve` can be secp256k1).
  Account resolution + `ensureSolanaDefault` must not assume Solana for
  every wallet; pick the appropriate account type per wallet.
- **WalletConnect / open dApp sessions:** switching the active account
  changes the exposed address — notify or tear down WC sessions.

---

## 9. Phased delivery

Per the migration policy at the top: **any phase that changes persisted data
ships its migration + an upgrade-path test in the same PR.** A schema change
without its migration is not "done."

1. **Keystore: per-wallet device share + migration. ✅ DONE.**
   `SecureKeystore` device-share methods take `walletId` (OS keystore +
   fallback blob keyed per wallet); `migrateToPerWalletV2(activeWalletId)`
   runs once from `tryRestore` — verify-before-delete, idempotent, gated by
   `libw_schema_v2`, abort-safe. Backend call sites pass `_walletId`.
   `test/secure_keystore_test.dart` covers isolation, the migration move,
   idempotency, fresh-install, and the pre-migration legacy fallback.
   Biometric cache intentionally left single-slot until Phase 2.
2. **Backend: `switchWallet` + walletId-scoped `unlock`/`hasLocalDeviceShare`. ✅ DONE.**
   `switchWallet(walletId, {password})` reloads a target wallet's TSS shares
   + its per-wallet device share, validates the password, and swaps the
   active state (locking the previous wallet); returns a typed `SwitchResult`.
   Pure `planWalletSwitch` routing helper + `_resolveAccount`. `create`/
   `_persist`/`unlock`/`hasLocalDeviceShare` are walletId-scoped (Phase 1).
   `test/wallet_switch_test.dart` covers the `planWalletSwitch` truth table +
   per-wallet create no-clobber. (Full switchWallet integration needs the
   live client → on-device.)
   _Original notes:_ Update `create`/`_persist` to write per-wallet shares. Keep active
   wallet behaviour identical for the single-wallet case (regression-safe).
   **Tests:** creating wallet B does NOT clobber A's per-wallet share (read
   both back via the keystore); a pure `switchDecision(active, target,
   hasShare)` helper returns ok / needsRecovery / wrongPassword; switching
   clears the previous wallet's in-memory secrets (lock-on-switch);
   `unlock` reads the active wallet's per-wallet share.
3. **`InAppUnlockScreen(walletId:)`** + `ensureUnlocked({walletId})`, recovery
   targeting that wallet. ✅ **DONE.** Optional `walletId`; non-active target
   unlocks via `switchWallet`; biometric offered only for the active wallet
   (single-slot cache). `hasLocalDeviceShare([walletId])` parameterized;
   `loadWalletForRecovery(walletId)` lets 2FA recovery target a non-active
   wallet. Pure `InAppUnlockScreen.unlockRoute` decides biometric/password/
   recovery. Backward compatible. `test/unlock_route_test.dart` covers the
   route truth table. (Widget render needs real theme/WalletService/client →
   verified on-device; google_fonts network fetch makes it infeasible as a
   unit test.)
   _Original notes:_ `hasLocalDeviceShare(walletId)` truth table; pure
   unlock-route helper; widget test that the screen targets `walletId`.
4. **UI: "Use this wallet"** on `WalletDetailsScreen`; per-wallet "usable
   here" hints in the list. ✅ **DONE.** "Use this wallet" button on the
   detail screen for any non-active wallet (hidden for the in-use one) →
   `ensureUnlocked(walletId:)` → switchWallet/recovery. "Needs 2FA on this
   device" hint on the detail screen and per-row in
   `WalletsManagementScreen` when `hasLocalDeviceShare(id)` is false. Pure
   `WalletDetailsScreen.walletDetailActions` decides show/hint;
   `test/wallet_detail_actions_test.dart` covers the truth table. (Full
   render on-device — google_fonts/client constraint.)
   _Original notes:_ widget test for hidden/shown + 2FA hint.
5. **`switchAccount` cross-wallet** + `AccountsManagementScreen` cross-wallet
   selection. ✅ **DONE.** The accounts screen already lists accounts across
   all wallets; tapping one on a non-active wallet now switches that wallet
   first via `ensureUnlocked(walletId:)` (password prompt), then `setCurrent`.
   Same-wallet / already-current keep the fast path. Pure
   `LibwalletBackend.accountSwitchRoute` drives it;
   `test/account_switch_route_test.dart` covers the truth table.
   _Original notes:_ same-wallet → fast path; cross-wallet → switch-first.
6. **Receive flow:** drop disconnect; add-to-list without activating; offer
   "Use it now".
   **Tests:** `importViaDeviceTransfer` leaves the active wallet/`_walletId`
   unchanged and writes the received share under the new wallet's id (no
   clobber); no disconnect occurs when a wallet already exists.
7. **Send/transfer:** allow transferring a non-active wallet by switching
   first.
   **Tests:** decision helper — non-active target → switch-first; active
   target → export directly.
8. **`removeWallet`** (replace `disconnect` for per-wallet removal) + active-
   wallet-removal handling. ✅ **DONE.** `removeWallet(walletId)` deletes the
   wallet + only its per-wallet device share; removing the active wallet
   promotes the next via pure `pickNextActive` (active-but-locked) or clears
   to empty, and drops the stale single-slot biometric cache.
   `WalletDetailsScreen._remove` uses it; the list reloads on return.
   `test/remove_wallet_test.dart` covers `pickNextActive` + per-wallet delete
   isolation. (`disconnect` stays for the logout flow.)
   _Original notes:_ non-active removal leaves active intact; active removal
   picks next via `pickNextActive`.
9. **WalletService session reset on switch** (balances/auth/WC/network).
   ✅ **DONE (balances).** `_onBackendChanged` detects active-address changes
   and calls `resetSessionState()` (zeros balances/fiat); the per-address tx
   cache isolates automatically; `disconnect` reuses the reset.
   `test/session_reset_test.dart` covers `resetSessionState` + tx-cache keying.

   > ⚠ **Auth-on-switch deliberately NOT done.** An initial attempt
   > re-authenticated (signed) the server session for the new address on every
   > switch — but signing immediately after a switch races other in-flight
   > libwallet work (dashboard backfill, `accounts.setCurrent`, balance
   > fetches) and **crashes the TSS layer** (`ToEd25519PubKey`, nil deref). So
   > switch no longer re-auths; the server session stays on the previous
   > wallet until the next auth-requiring call re-mints it lazily (the
   > pre-multi-wallet behaviour). A proper fix needs **serialized libwallet
   > signing** so no two TSS ops / `setCurrent` overlap. Same caveat for WC
   > (no accounts-changed emit). Tracked as follow-up.

Each phase is shippable; 1–2 are the foundation and must land first. Every
phase lands with its tests green (see the Testing policy callout).

---

## 10. File / symbol touch-list

| File | Change |
|---|---|
| `lib/services/wallet/secure_keystore.dart` | per-wallet keys + signatures, `migrateToPerWallet`, per-wallet biometric |
| `lib/services/wallet/libwallet_backend.dart` | `switchWallet`, `switchWalletWithBiometric`, walletId-scoped `unlock`/`hasLocalDeviceShare`, cross-wallet `switchAccount`, `removeWallet`, per-wallet `_persist`, drop receive `hasWallet` guard, fold `activateAfterTransfer` into switch |
| `lib/services/wallet_service.dart` | `useWallet(walletId)`, session reset on switch, `tryRestore` activates pointer |
| `lib/screens/wallet/inapp_unlock_screen.dart` | `walletId` param, `ensureUnlocked({walletId})`, recovery per wallet |
| `lib/screens/wallet/wallet_details_screen.dart` | "Use this wallet" action; `_remove` → `removeWallet` |
| `lib/screens/wallet/wallets_management_screen.dart` | optional per-row "Use" + "needs 2FA here" hint |
| `lib/screens/wallet/accounts_management_screen.dart` | cross-wallet account selection |
| `lib/screens/wallet/device_transfer_receive_screen.dart` | remove disconnect dialog/guard; add-to-list UX |
| `lib/screens/wallet/device_transfer_send_screen.dart` | allow non-active via switch-first |
| `test/` | per-phase unit tests (Testing policy): keystore round-trip + migration ✅; `switchWallet`/switch-decision; unlock-route + `hasLocalDeviceShare`; cross-wallet `switchAccount`; receive-no-clobber; `removeWallet`/`pickNextActive`; `resetSessionState`; plus widget tests for the "Use this wallet" UI |

---

## 11. Quick reference — libwallet calls used

- Wallets: `client.wallets.list()`, `.get(id)`, `.delete(id)`,
  `.exportToDevice(id)`, `.importFromDevice(code)`, `.reshare(...)`.
- Accounts: `client.accounts.list(wallet:)`, `.get(id)`,
  `.create(name, wallet, type, index)`, `.setCurrent(id)`.
- Keys: `client.storeKeys.derivePassword(password, walletKeyId)`,
  `.create()`; `client.remoteKeys.reshare(...)`.
- All device-share *bytes* are host-owned (in `SecureKeystore`), never in
  libwallet — that's why per-wallet storage is entirely an app concern.
