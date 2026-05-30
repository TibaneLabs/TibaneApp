# libwallet device-to-device wallet transfer — implementation reference

Portable reference for any Flutter app built on **libwallet** that wants a
"move my wallet to my new phone" flow over a QR code. Verified against
**libwallet 0.4.46** (Dart, pub.dev). Nothing here is app-specific — the
class/method names are libwallet's; adapt the keystore and wallet-service
glue to your own host.

> TL;DR — libwallet ships a first-party device-transfer API
> (`Wallet:exportToDevice` / `Wallet:importFromDevice`). It moves the
> wallet JSON **and the device (StoreKey) share** between two phones over
> an encrypted, single-use, 5-minute channel, gated by a confirmation +
> biometric on the **old** device. Because the device share travels, the
> new phone does **not** need the 2FA/reshare ceremony that a file backup
> would force. Do **not** roll your own "password-in-the-QR" scheme — this
> API is strictly more secure.

---

## 1. The mental model you must get right first

libwallet wallets are TSS (threshold) wallets split into shares. The
common shape is **2-of-3**:

| Share | Lives where | Role |
|---|---|---|
| **StoreKey** ("device share") | the host's platform keystore (Keychain/Keystore) | physical-possession factor |
| **Password** | derived from the user's password (nothing stored) | knowledge factor |
| **RemoteKey** | the libwallet server | recovery / 2FA factor, held in reserve |

Day-to-day signing on most hosts uses **StoreKey + Password**. The
RemoteKey is only pulled in for recovery (e.g. when the device share is
missing and must be re-minted via a reshare).

**Why this matters for transfer UX:**

- A **file/JSON backup** (`Wallet:backup`) deliberately **omits the
  StoreKey** — it's safe to store on iCloud/Drive precisely because it's
  not single-factor. Restoring it on a new device leaves the device share
  absent, so the host must run a **RemoteKey reshare ceremony** (the "2FA"
  step) on first unlock to mint a fresh device share.
- **Device transfer** (this doc) **carries the StoreKey across**. The new
  device ends up holding StoreKey + Password — identical to a normal,
  already-set-up wallet. **No reshare. No per-transaction 2FA.**

So the only thing the user does on the new device after a transfer is the
**normal unlock** (type the wallet password once, or biometric) — needed
because the Password share *is* the password. If your host's signing path
uses the Password share (most do), there is no way around that one prompt
*without* re-architecting signing to StoreKey + RemoteKey, which removes
the password spend-gate and is **not recommended**.

---

## 2. The API surface

All methods hang off `client.wallets` (`WalletApi`). Models are exported
from `package:libwallet/libwallet.dart`:
`DeviceTransferSession`, `DeviceShareEntry`, `DeviceTransferImportResult`.

```dart
// OLD device — open a session, get the QR payload.
Future<DeviceTransferSession> exportToDevice(String walletId);
//   → { String sid, String pairingCode, DateTime expiresAt }
//   pairingCode is OPAQUE. Render it verbatim as a QR. Do not parse it.
//   Session: 5-minute TTL, single-use. expiresAt drives a countdown.

// OLD device — approve after the new device connects + biometric.
Future<void> exportToDeviceConfirm({
  required String sid,
  required List<DeviceShareEntry> deviceShares,
});

// OLD device — decline / abort. Idempotent, safe any time.
Future<void> exportToDeviceCancel(String sid);

// NEW device — drive the import. BLOCKS up to ~2 min while the old
// device's user confirms; throws a coded LibwalletException on failure.
Future<DeviceTransferImportResult> importFromDevice(String pairingCode);
//   → { String walletId, List<DeviceShareEntry> deviceShares }
```

### Models

```dart
class DeviceTransferSession {
  final String sid;          // pass to confirm/cancel
  final String pairingCode;  // paint as QR (opaque)
  final DateTime expiresAt;  // default +5 min
  bool get isExpired;        // DateTime.now() > expiresAt
}

class DeviceShareEntry {
  final String walletKeyId;  // == WalletKey.id of the StoreKey share
  final String privateKey;   // 64-byte StoreKey blob, base64url (no pad)
  Map<String, dynamic> toJson(); // {'wallet_key_id':…, 'private_key':…}
}

class DeviceTransferImportResult {
  final String walletId;
  final List<DeviceShareEntry> deviceShares; // usually exactly one
}
```

---

## 3. The handshake, end to end

```
OLD device (wallet lives here)            NEW device (empty)
─────────────────────────────            ──────────────────
exportToDevice(walletId)
  → { sid, pairingCode, expiresAt }
paint pairingCode as QR ───────────────► scan QR
                                          importFromDevice(pairingCode)
                                            (blocks, waiting…)
◄── wallet:transfer:pair_received event ──
    { sid, wallet_id, peer_spot_id,
      peer_fingerprint? }
show confirm prompt (peer_fingerprint)
biometric check
read StoreKey private from keystore
exportToDeviceConfirm(sid, [DeviceShareEntry]) ─┐
                                                 │ libwallet seals
                                                 │ wallet JSON + share
                                                 ▼ (AES-256-GCM over Spot)
                                          importFromDevice resolves
                                            → { walletId, deviceShares }
                                          write each deviceShare.privateKey
                                            to platform keystore
                                          (wallet:restored event also fires)
                                          user unlocks with password → done
```

### Old-device timing constraints

- The session is valid **5 minutes** (`expiresAt`). Show a countdown; hide
  the QR when `isExpired`.
- After the `wallet:transfer:pair_received` event fires you must call
  **`exportToDeviceConfirm` or `exportToDeviceCancel` within ~90 s** — the
  handler times out after that and the new device gets a `timeout` error.

### New-device behaviour

- `importFromDevice` **blocks for up to ~2 minutes**. Run it without
  blocking your UI; show a "waiting for the other device to confirm…"
  state with a cancel affordance.
- On success the wallet is **already written to libwallet's local store**
  (same path `Wallet:restore` uses; the `wallet:restored` host event
  fires). You only need to persist the device share + your own metadata.

---

## 4. Receiving host events (`wallet:transfer:pair_received`)

There is **no typed event class** for this — it arrives on the generic
event stream as an `UnknownEvent`. Match it by name:

```dart
final sub = client.events
    .where((e) => e.event == 'wallet:transfer:pair_received')
    .listen((e) async {
  final sid           = e.data['sid'] as String?;
  final walletId      = e.data['wallet_id'] as String?;
  final peerSpotId    = e.data['peer_spot_id'] as String?;
  final fingerprint   = e.data['peer_fingerprint'] as String?; // optional

  // Match sid against the session you opened, then prompt + confirm.
});
```

`client.events` is a **broadcast** `Stream<LibwalletEvent>`. Filter to the
`sid` you opened (more than one transfer could theoretically be in
flight). Cancel the subscription when the send screen closes.

> Note: you already know the StoreKey's `walletKeyId` locally (it's the id
> of the wallet's `StoreKey`-typed `WalletKey`). You don't need the event
> to tell you which key to send; `wallet_id` just lets you assert it's the
> wallet you intended to transfer.

---

## 5. Old device — producing the `DeviceShareEntry`

libwallet does **not** store the StoreKey private key — your host owns it
(in the platform keystore / in memory after unlock). To confirm:

```dart
// You already hold these when the wallet is unlocked:
//   storeKeyWalletKeyId  — id of the StoreKey-typed WalletKey
//   storeKeyPrivate      — base64url 64-byte blob (what StoreKey:create
//                          returned in `private`; same shape you persisted)

final entry = DeviceShareEntry(
  walletKeyId: storeKeyWalletKeyId,
  privateKey:  storeKeyPrivate,
);
await client.wallets.exportToDeviceConfirm(sid: sid, deviceShares: [entry]);
```

Gate this behind a biometric prompt (user presence) before reading the
key and confirming, per the protocol's threat model. If your keystore
entry is itself biometric-gated, the read *is* the gate.

---

## 6. New device — persisting the transferred share

This is the step that makes the wallet usable. **Write the device share to
your keystore BEFORE the next unlock/sign call**, or your host's
"device share not found" guard will fire and the wallet will look imported
but be unable to sign.

```dart
final result = await client.wallets.importFromDevice(code);

for (final share in result.deviceShares) {
  // RECOMMENDED: verify the private's public half matches the wallet's
  // stored StoreKey `Key` (X.509 public) before trusting it. A mismatched
  // key loads but produces unverifiable signatures.
  await keystore.writeDeviceShare(
    walletKeyId: share.walletKeyId,
    value: share.privateKey,
  );
}

// Fetch the wallet, pick/create the account you need (e.g. an ed25519
// Solana account at index 0 if the restore didn't include one), persist
// your own wallet metadata (walletId, accountId, address, key ids).
// Then the user unlocks with the ORIGINAL wallet password — normal path.
```

Notes:
- Some keystores write a password-encrypted fallback blob in addition to
  the OS keychain copy. You won't have the password at `importFromDevice`
  time (the whole point), so either (a) write only the OS-keychain copy
  now and add the fallback blob after the user enters their password at
  first unlock, or (b) keep the share in memory and write it during the
  unlock call. Don't block the import on a password you don't have yet.
- The password the user types on the new device must be the **original
  wallet's password** — the Password share is derived from it.

---

## 7. Error handling

`importFromDevice` throws a raw **`LibwalletException`** (fields:
`String message`, `String code`). The wire error code is embedded in
`message`. libwallet exports typed `Pairing*Exception` classes but **does
NOT auto-map them for `importFromDevice`** (only the ClawdWallet `pair`
flow does). Mirror that mapping yourself:

```dart
try {
  final result = await client.wallets.importFromDevice(code);
} on LibwalletException catch (e) {
  final m = e.message;
  bool has(String c) => m == c || m.contains(c);
  if (has('url_malformed'))      // bad/garbage QR
  else if (has('token_invalid'))
  else if (has('token_expired')) // QR > 5 min old → regenerate
  else if (has('declined'))      // user said no on the old device
  else if (has('timeout'))       // old device didn't confirm in time
  else if (has('session_not_found'))
  else if (has('peer_unreachable')) // Spot couldn't reach old device
  else /* bad_request → fail closed */;
}
```

Friendly UI copy suggestions: `declined` → "Transfer declined on the other
device."; `token_expired` → "QR code expired — generate a new one.";
`peer_unreachable` → "Couldn't reach the other device. Are both online?".

---

## 8. Security properties (why this is safe as the default migration UX)

- **Out-of-band token.** The QR carries a fresh 32-byte random; the
  payload is encrypted with a key derived from that token via HKDF-SHA-256.
  An attacker on the Spot transport can't decrypt without the QR.
- **Old-device confirmation + biometric.** Even a shoulder-surfed QR can't
  pull the wallet — the payload is only released after the source-device
  user approves the prompt and passes biometric.
- **5-minute, single-use.** Once the new device's request lands the
  session burns; a captured QR can't be replayed.
- **Nothing touches disk.** No backup file to misplace, no third-party
  storage in the threat model.

The reshare-on-missing-device-share path stays as the fallback for users
who **lost** the old device (they can't run a device-to-device flow).

---

## 9. Hard requirements & gotchas

- **libwallet ≥ 0.4.46** for the device-transfer API. (Reshare runs
  end-to-end in <1s on ≥ 0.4.35, relevant only for the lost-device
  fallback.)
- **Both devices must be online** and reachable over libwallet's **Spot**
  transport for the duration. This is Go-side; you can't fully verify it
  from Dart — test on two real devices, ideally iOS ↔ Android.
- **Old device must be unlocked** (StoreKey private in hand) to confirm.
- `importFromDevice` is **blocking (~2 min)** and the confirm window is
  **~90 s** after `pair_received` — design the UI around those.
- **Treat `pairingCode` as opaque.** Its current encoding is a
  `tibane://device-transfer?…` URL but that may change without a
  wire-format bump.
- **Verify the transferred StoreKey** public half against the wallet's
  stored `Key` before writing it to the keystore.
- The default `Wallet:backup` JSON stays **device-share-free** — don't be
  tempted to stuff the StoreKey into a file backup to "simplify"; that
  collapses the 2-of-3 into a single-factor secret. Device transfer is the
  sanctioned way to move the share.

---

## 10. Reference: source locations in the libwallet package

- `lib/src/api/wallet_api.dart` — `exportToDevice`, `exportToDeviceConfirm`,
  `exportToDeviceCancel`, `importFromDevice` (read the doc comments).
- `lib/src/models/device_transfer.dart` — the three models.
- `lib/src/events/events.dart` — `LibwalletEvent` hierarchy;
  `client.events` stream; unknown events fall to `UnknownEvent`.
- `lib/src/client/libwallet_client.dart` — `client.events` getter.
- `lib/src/exceptions/pairing.dart` — typed pairing exceptions (the
  catalogue to mirror).
- `lib/src/api/clawdwallet_api.dart` `_toPairingException` — the canonical
  message→exception mapping recipe to copy.
- `doc/device_share.md` — the protocol writeup ("Device-to-device transfer"
  section) bundled inside the package.
