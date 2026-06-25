import 'package:libwallet/libwallet.dart' show Wallet, WalletKey;

/// Per-transaction (lockless) signing — pure helpers + feature flag.
///
/// Phase 1 of the Atonline-parity migration (ATONLINE_PARITY_MIGRATION.md §4.3,
/// §3.2, §7). These functions encode the share-counting rules so they can be
/// unit-tested without a device, libwallet client, or BuildContext (the
/// existing `pickNextActive` / `walletDetailActions` pattern). The UI sheet,
/// the biometric/keystore reads, and the real libwallet signature are
/// device-verified.

/// Feature flag for the lockless, per-transaction signing path.
///
/// When `false` (the shipped default), signing keeps using the app-level
/// `unlock()` session + cached `_signingKeys()`. When `true`, the wired flows
/// collect shares per transaction via the sign sheet instead. Phase 1 ships
/// this OFF (the new path is present but dormant, in parallel — §7).
///
/// Driven by `--dart-define` so it can be flipped on for device validation
/// without editing code and without leaving a non-default committed:
///   flutter run --dart-define=LOCKLESS_SIGNING=true
/// (Environment-based so the wired branches aren't flagged as dead code.)
const bool kLocklessSigning = bool.fromEnvironment('LOCKLESS_SIGNING');

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
