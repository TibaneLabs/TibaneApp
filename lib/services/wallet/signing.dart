import 'package:libwallet/libwallet.dart'
    show KeyDescription, SigningKey, Wallet, WalletKey;

/// Per-transaction (lockless) signing — pure helpers + feature flag.
///
/// Phase 1 of the Atonline-parity migration (ATONLINE_PARITY_MIGRATION.md §4.3,
/// §3.2, §7). These functions encode the share-counting rules so they can be
/// unit-tested without a device, libwallet client, or BuildContext (the
/// existing `pickNextActive` / `walletDetailActions` pattern). The UI sheet,
/// the biometric/keystore reads, and the real libwallet signature are
/// device-verified.

/// Number of key shares libwallet needs to produce a signature: `threshold + 1`.
///
/// S1 is resolved (§3.2): `Wallet.threshold` is the (t,n) "max shares that may
/// be missing"; signing needs `t + 1` parties. A standard 2-of-3 wallet has
/// `threshold == 1` → 2 shares (StoreKey + Password). Biometric-only signing is
/// impossible by construction (min threshold 1 ⇒ min 2 shares).
int requiredSigningShares(int threshold) => threshold + 1;

/// The key shares a user can actually supply on this device at sign time:
/// **StoreKey** (biometric / OS-keystore) + **Password** (typed). RemoteKey is
/// recovery-only and dormant at sign time (D9), so it's excluded from the set
/// the sign sheet asks the user to unlock.
List<WalletKey> collectibleSigningKeys(List<WalletKey> keys) =>
    keys.where((k) => k.isStoreKey || k.isPassword).toList();

/// Whether enough collectible shares exist to meet `threshold + 1` — i.e.
/// whether this committee can be signed on this device at all. When `false`
/// the wallet is unsignable here (e.g. only RemoteKey + one share) and the
/// caller should route to 2FA recovery (§4.8) rather than show a dead sheet.
bool canAssembleThreshold(Wallet wallet) =>
    collectibleSigningKeys(wallet.keys).length >=
    requiredSigningShares(wallet.threshold);

/// Whether the sheet has collected enough shares to enable "Confirm".
bool signSheetReady(int collectedCount, int threshold) =>
    collectedCount >= requiredSigningShares(threshold);

/// Whether a sign should authorize per-transaction via the sign sheet: every
/// in-app wallet does (signing is always lockless / per-transaction now). MWA
/// signs through Seed Vault's own auth, never the sheet.
bool useSignSheetFor({required bool isInApp}) => isInApp;

/// Extract the raw credentials a key-management op needs (change password,
/// rotate device share, reshare, …) from the shares the sign sheet collected:
/// the typed **Password** and (when present) the **StoreKey** private key.
///
/// Pure so it's unit-testable without a sheet. Phase 6D replaces the legacy
/// `unlock()` cached `_password`/`_storeKeyPriv` session with per-op collection,
/// and this maps the collected `List<SigningKey>` back to those two secrets.
/// `password` is null only if no Password share was collected (every committee
/// includes one, so callers can treat null as "cancelled / unusable").
({String? password, String? storeKeyPriv}) managementCredsFrom(
  List<SigningKey> keys,
) {
  String? password;
  String? storeKeyPriv;
  for (final k in keys) {
    if (k.type == 'Password') password ??= k.key;
    if (k.type == 'StoreKey') storeKeyPriv ??= k.key;
  }
  return (password: password, storeKeyPriv: storeKeyPriv);
}

/// Resolve the credentials a key-management op will actually use, given the
/// per-op values the caller passed (from the management-auth sheet) and the
/// legacy cached unlock session. **Per-op values win; the cache is the
/// fallback** — this is the precedence rule that lets Phase 6D convert an op to
/// param-based creds *additively*: new callers pass creds explicitly, old
/// callers (still relying on `unlock()`) pass null and fall through to the
/// cached `_password`/`_storeKeyPriv`, so both paths keep working until the
/// cache is deleted in 6D-4.
///
/// Pure so the precedence is unit-tested without a device or libwallet client.
({String? password, String? storeKeyPriv}) effectiveManagementCreds({
  String? paramPassword,
  String? paramStoreKeyPriv,
  String? cachedPassword,
  String? cachedStoreKeyPriv,
}) =>
    (
      password: paramPassword ?? cachedPassword,
      storeKeyPriv: paramStoreKeyPriv ?? cachedStoreKeyPriv,
    );

/// Build the OLD (authorizing) + NEW (target) committees for a management
/// reshare — change-password and rotate-device-share — per the libwallet
/// contract (see `lib/src/models/remote_key_session.dart`, the canonical
/// reshare recipe, + the libwallet team's guidance).
///
/// - **OLD = exactly the two shares this device holds** — the StoreKey and the
///   Password (T+1 for a 1-of-3 wallet) — each identified by its **current
///   WalletKey id** ([oldStoreKeyId]/[oldPasswordKeyId], which the reshare
///   resolves by). The StoreKey's `key` is the **64-byte device-share secret**
///   ([storeSecret]) — the same material used to sign, NOT its public. The
///   RemoteKey is deliberately excluded from OLD: it isn't an authorizer here,
///   and DKLS rejects an OLD list longer than T+1.
///
/// - **NEW = the full 3-share target committee.** The StoreKey `key` is the
///   **public** ([newStorePublic]) — the current one for a password change, a
///   freshly-minted one for a rotation. The RemoteKey `key` is the **fresh
///   RemoteKey session** ([newRemoteKey]) returned by `RemoteKey:validate` —
///   NOT empty and NOT a `wkey-…` id. A reshare re-splits the secret, so the
///   RemoteKey gets a brand-new share that must be pushed to the wdrone fleet
///   under an *active* session; minting that session is what sends the 2FA
///   code, so **2FA is unavoidable for a reshare** (it isn't for a plain sign).
///   The Password `key` is the raw [newPassword] (the new secret on a password
///   change; the unchanged one on a rotation).
///
/// Pure so the exact committee shape is locked down by unit tests without a
/// libwallet client. After the reshare the caller must re-read ALL new key ids
/// (the generation bumps and every share id changes).
({List<KeyDescription> oldKeys, List<KeyDescription> newKeys})
    buildManagementReshareCommittee({
  required String oldStoreKeyId,
  required String storeSecret,
  required String oldPasswordKeyId,
  required String oldPassword,
  required String newStorePublic,
  required String newRemoteKey,
  required String newPassword,
}) =>
        (
          oldKeys: [
            KeyDescription(
                type: 'StoreKey', id: oldStoreKeyId, key: storeSecret),
            KeyDescription(
                type: 'Password', id: oldPasswordKeyId, key: oldPassword),
          ],
          newKeys: [
            KeyDescription(type: 'StoreKey', key: newStorePublic),
            KeyDescription(type: 'RemoteKey', key: newRemoteKey),
            KeyDescription(type: 'Password', key: newPassword),
          ],
        );
