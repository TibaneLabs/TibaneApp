import 'package:libwallet/libwallet.dart' show Wallet, WalletKey;

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
