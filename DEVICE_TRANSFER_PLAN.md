# Device transfer (QR → new device) — implementation plan

Add a **"Device transfer"** feature that moves an in-app wallet to a new
phone over libwallet's first-party device-transfer API. Sits **alongside**
the existing Export / Import (file + backup-QR) flows — those stay
unchanged.

End state: scan QR on the new phone → old phone confirms with biometric →
wallet **and the device (StoreKey) share** land on the new phone → user
unlocks with the wallet password → it's a normal wallet (StoreKey +
Password signing, **no 2FA reshare, no per-tx 2FA**).

See `LIBWALLET_DEVICE_TRANSFER.md` for the protocol/security details (also
the doc to send to the other project). This file is the tibane wiring.

---

## Status

**Receive side: BUILT** (this device = the new phone).
- `libwallet_backend.dart`: `importViaDeviceTransfer(pairingCode)`,
  `activateAfterTransfer(password)`, `abandonPendingTransfer()`, and the
  `_friendlyTransferError` mapper.
- `lib/screens/wallet/device_transfer_receive_screen.dart`: scan → wait →
  password → activate, with cancel/rollback handling.
- If an in-app wallet already exists, scanning a valid code prompts a
  Yes/No "Disconnect current wallet?" dialog; **Yes** calls
  `libwallet.disconnect()` (removes the local wallet + device-share key)
  then proceeds with the transfer, **No** returns to scanning. The dialog
  warns that the current wallet must be backed up since disconnect wipes
  its local device key.
- Entry point: "Receive wallet from another device" in
  `wallets_accounts_screen.dart`.
- Persistence is deferred to `activateAfterTransfer` so a cancelled
  transfer never strands a half-set-up wallet.

**Send side: BUILT** (this device = the old/source phone).
- `libwallet_backend.dart`: `startDeviceTransferExport()` (→ `exportToDevice`),
  `confirmDeviceTransferExport(sid)` (→ `exportToDeviceConfirm`, releases the
  StoreKey share), `cancelDeviceTransferExport(sid)`.
- `lib/screens/wallet/device_transfer_send_screen.dart`: `exportToDevice` →
  QR + 5-min countdown → listens on `client.events` for
  `wallet:transfer:pair_received` (matched by `sid`) → confirm dialog (shows
  `peer_fingerprint`) → `exportToDeviceConfirm`. Best-effort `cancel` on
  dispose/decline/expiry.
- **Entry point: per-wallet, from the wallet list.** "Transfer to a new
  device" lives on `WalletDetailsScreen` (Manage wallets → tap a wallet),
  which feeds that wallet's `walletId` + name into the send screen. It is
  NOT in the settings menu (a global entry couldn't say which wallet).
- The send screen is scoped to that `walletId`:
  `startDeviceTransferExport(walletId)` requires it to be the **active**
  wallet (only the active wallet's StoreKey share is in the keystore). If
  it isn't active, the screen says to open it first. If it's
  connected-but-locked, a Yes/No "Unlock {name}?" dialog routes through
  `InAppUnlockScreen.ensureUnlocked` (biometric → password/2FA) before
  opening the session — no dead-end "unlock first" error.

> Limitation: transfer only works for the wallet currently "In use" (the
> app keeps one in-app wallet's device share in the keystore at a time).
> Transferring a non-active wallet would need per-wallet device-share
> storage + a wallet-switch flow — not built.
- Entry point: "Transfer this wallet to a new device" in
  `wallets_accounts_screen.dart` (next to the receive tile).
- Logs every `wallet:transfer:*` / `online_status` event under
  `[device-transfer] export event:` — doubles as the reverse-direction
  diagnostic (does `pair_received` arrive when Tibane is the source?).

**Known rough edge:** cancelling *during* the ~2-min wait pops the screen
while `importFromDevice` is still in flight; when it later resolves it sets
in-memory fields with no UI attached. `abandonPendingTransfer` covers the
password/error exits and the next pop, but a mid-wait cancel may need a
follow-up activation prompt or an explicit in-flight cancel. Acceptable for
testing; revisit if it bites.

---

## Why this is distinct from the existing import

`importFromBackup` (`libwallet_backend.dart:1367`) sets `_storeKeyPriv =
null` on purpose — the file backup omits the StoreKey, so first unlock
routes through the 2FA RemoteKey reshare. Device transfer **ships the
StoreKey**, so the new device skips reshare entirely and lands in the same
state as `unlock()` leaves a normal wallet: `_storeKeyId` + `_storeKeyPriv`
+ `_password` all set → `_signingKeys()` returns StoreKey + Password
(`libwallet_backend.dart:1580`).

---

## Tasks

### 1. Backend — `LibwalletBackend` (`lib/services/wallet/libwallet_backend.dart`)

**Old-device (send) side:**

- [ ] `Future<DeviceTransferSession> startDeviceTransfer()`
  - Guard: `hasWallet && isUnlocked` (need `_storeKeyId` + `_storeKeyPriv`
    in memory to confirm later). Return/throw clearly if locked.
  - `return await client.wallets.exportToDevice(_walletId!);`
- [ ] Expose the `wallet:transfer:pair_received` event to the UI. Add a
  subscription helper, e.g.
  `Stream<Map<String,dynamic>> pairRequests(String sid)` that filters
  `client.events.where((e) => e.event == 'wallet:transfer:pair_received'
  && e.data['sid'] == sid)`. The send screen owns the lifetime.
- [ ] `Future<void> confirmDeviceTransfer(String sid)`
  - Build `DeviceShareEntry(walletKeyId: _storeKeyId!, privateKey:
    _storeKeyPriv!)`.
  - `await client.wallets.exportToDeviceConfirm(sid: sid, deviceShares:
    [entry]);`
  - Caller is responsible for the biometric gate (see screens) — or gate
    here via `_keystore.readBiometricPassword()` when biometric is enabled.
- [ ] `Future<void> cancelDeviceTransfer(String sid)` →
  `client.wallets.exportToDeviceCancel(sid)` (idempotent; call on
  decline / screen dispose / expiry).

**New-device (receive) side:**

- [ ] `Future<DeviceTransferImportResult> importViaDeviceTransfer(String
  pairingCode)`
  - Guard: `!hasWallet` (mirror `importFromBackup`'s
    "disconnect first" guard).
  - `final result = await client.wallets.importFromDevice(pairingCode);`
  - Resolve the restored wallet: `client.wallets.get(result.walletId)` (or
    list + match id). Extract key ids via `_extractKeyIdsByType`.
  - Pick the ed25519 `solana` account; create one at index 0 if absent
    (same logic as `importFromBackup`).
  - Verify each `deviceShares[].walletKeyId == keyIds['StoreKey']` and
    (recommended) that its public half matches the wallet's StoreKey
    `Key`. Stash `_storeKeyPriv = deviceShares.first.privateKey`,
    `_storeKeyId = keyIds['StoreKey']`, plus
    `_walletId/_accountId/_publicKey/_walletName/_passwordKeyId/
    _remoteKeyId`. Persist prefs (same set `importFromBackup` writes).
  - **Do NOT** write the device share to the keystore here — no password
    yet. Keep it in memory and return the result.
- [ ] `Future<bool> activateAfterTransfer(String password)` (or reuse a
  branch of `unlock`)
  - `await client.storeKeys.derivePassword(password:, walletKeyId:
    _passwordKeyId!)` to validate; on `LibwalletException` → wrong
    password.
  - `_password = password;`
  - `await _keystore.writeDeviceShare(value: _storeKeyPriv!, password:
    password);` (now both OS-keystore copy + fallback blob get written).
  - `notifyListeners(); unawaited(ensureSolanaDefault());` → wallet is
    live, signs normally. No reshare.

> Reuse note: `activateAfterTransfer` is `unlock()` minus the
> `readDeviceShare` step (the share is already in memory). Consider a
> shared private helper to avoid drift.

### 2. Error mapping

- [ ] Add a small mapper for `importViaDeviceTransfer` that turns the
  `LibwalletException` code-in-message into friendly strings:
  `declined`, `token_expired`, `peer_unreachable`, `timeout`,
  `session_not_found`, `url_malformed`, `token_invalid`, else generic.
  (Mirror `clawdwallet_api.dart`'s `_toPairingException`.) Keep it in the
  backend or a tiny helper so both screens share it.

### 3. Screens (`lib/screens/wallet/`)

- [ ] `device_transfer_send_screen.dart` (old device)
  - On open: call `startDeviceTransfer()`, render `pairingCode` as a QR
    (reuse the white-card `QrImageView` styling from
    `qr_backup_export_screen.dart` / `receive_screen.dart`). Boost screen
    brightness while shown.
  - Show a countdown to `session.expiresAt`; when expired, offer
    "Generate new code".
  - Subscribe to `pairRequests(sid)`. On event: show a confirm dialog with
    the `peer_fingerprint`, then a **biometric** prompt, then
    `confirmDeviceTransfer(sid)`. Respect the ~90 s window (timer + auto
    `cancelDeviceTransfer`).
  - States: waiting → pair received (confirm?) → sealing → done / declined
    / expired / error.
  - `cancelDeviceTransfer(sid)` on dispose if still open.
- [ ] `device_transfer_receive_screen.dart` (new device)
  - Camera scanner (reuse / generalize `qr_backup_scan_screen.dart`'s
    `MobileScanner` setup). On first QR → `importViaDeviceTransfer(raw)`.
  - Show a blocking-but-cancellable "Waiting for the other device to
    confirm… (up to ~2 min)" state.
  - On success → push a password prompt → `activateAfterTransfer(pw)` →
    `wallet.useLibwallet()` → pop `true`.
  - On `LibwalletException` → friendly message via the mapper; let the user
    retry / rescan.

### 4. Entry point (per "add alongside")

- [ ] Add a **"Device transfer"** item to
  `lib/screens/settings/wallets_accounts_screen.dart` (next to the
  existing Export/Import entries at lines ~93/102). It opens a small
  chooser screen with two actions:
  - "Transfer this wallet to a new device" → `DeviceTransferSendScreen`
    (requires an unlocked wallet).
  - "Set up this device from another phone" → `DeviceTransferReceiveScreen`
    (requires no current wallet).
- [ ] Optional: surface "Transfer to a new device" in
  `wallet_details_screen.dart` and/or the `wallet_button.dart` menu, same
  as Export is today.

### 5. Scanner reuse (optional cleanup)

- [ ] `qr_backup_scan_screen.dart` is hard-wired to decode the `TIBW1:`
  backup envelope. Extract its `MobileScanner` + overlay + torch/camera
  chrome into a reusable widget that just returns the raw scanned string;
  have the backup-import screen keep its `decodeBackupJsonFromQr` step and
  the device-transfer receive screen pass the raw `pairingCode` straight
  to `importViaDeviceTransfer`. Skip if you'd rather keep them separate.

### 6. Manual test plan (two real devices — not the simulator)

- [ ] Same-account A→B: transfer, then on B confirm the Solana address +
  balances match, and **send a transaction without any reshare/2FA
  prompt** (proves StoreKey transferred and signing is StoreKey+Password).
- [ ] iOS ↔ Android both directions.
- [ ] Decline on the old device → new device shows "declined", can retry.
- [ ] Let the QR sit > 5 min → new device scan → "expired"; regenerate.
- [ ] Don't confirm within ~90 s → new device "timeout".
- [ ] One device offline → "peer_unreachable".
- [ ] Wrong password at `activateAfterTransfer` → clear error, share stays
  in memory, retry works.
- [ ] After successful transfer, enable biometric unlock on the new device
  and confirm it works (writes the biometric password cache).

### 7. Open questions / risks to confirm on-device

- [ ] **Spot transport**: confirmed available in this build? The whole
  flow depends on it; can't verify from Dart. First milestone is a smoke
  test that `pair_received` fires at all.
- [ ] **Biometric gate** mechanism on confirm: reuse
  `SecureKeystore.readBiometricPassword()` (triggers FaceID/fingerprint)
  vs. add `local_auth`. The wallet's biometric cache may not be enabled —
  fall back to a password re-entry on the old device in that case.
- [ ] **`exportToDevice` preconditions**: does it require the wallet to be
  in a specific server-side state? Verify it doesn't error for a healthy
  unlocked wallet.
- [ ] **`peer_fingerprint` absence**: handle the confirm dialog gracefully
  when the event omits it.
- [ ] Decide whether to keep the device-transfer screens behind the same
  UK-compliance gate logic as swap/staking (it's wallet management, so
  likely **not** gated — confirm).

---

## Files

**New**
- `lib/screens/wallet/device_transfer_send_screen.dart`
- `lib/screens/wallet/device_transfer_receive_screen.dart`
- (optional) a small `DeviceTransferChooserScreen` or inline buttons in
  the settings screen.

**Edited**
- `lib/services/wallet/libwallet_backend.dart` — the 5 methods above + the
  error mapper.
- `lib/screens/settings/wallets_accounts_screen.dart` — entry point.
- (optional) `lib/screens/wallet/qr_backup_scan_screen.dart` — extract
  reusable scanner.

**Edited (backup-QR feature removed — QR is now device-transfer only)**
- `inapp_import_screen.dart` — dropped the "Scan QR code" button + handler;
  import is now file/paste only.
- `inapp_export_screen.dart` — dropped "Show as QR code"; export is now
  share-file / copy only.

**Deleted (orphaned once the import scanner was removed)**
- `lib/screens/wallet/qr_backup_scan_screen.dart`
- `lib/screens/wallet/qr_backup_export_screen.dart`
- `lib/services/wallet/qr_backup_codec.dart`
- `test/qr_backup_codec_test.dart`
