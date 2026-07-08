    # Error Display Audit — Friendly, Central, Debuggable Errors

**Status:** Audit / design proposal (not yet implemented)
**Author:** generated from a full sweep of `tibaneapp/lib` + `libwallet/`
**Date:** 2026-07-08

## 1. Problem

Today the app surfaces **raw error strings straight from libwallet** — which itself
forwards raw messages from chains, RPC nodes, and swap aggregators — directly to
users. A user who runs out of SOL sees:

```
Transaction simulation failed: Error processing Instruction 5: custom program error: 0xb
```

instead of "Not enough SOL to cover the network fee." Roughly **40% of the ~75
error-display sites** in the app pass `$e` verbatim to a `SnackBar` or inline
`Text`. The rest are inconsistent: some use a per-screen `_friendlyError()`, some
read a backend `error` string, a few have excellent bespoke mapping. There is no
single place that turns a libwallet error into a human message, and no consistent
way to keep the raw text available for debugging.

## 2. Goal (agreed scope)

Deliver three things:

1. **Friendly message mapping** — map known error signatures (no internet,
   blockhash expired, insufficient funds, slippage, user-rejected, wrong password,
   quote expired, …) to clear, human messages.
2. **Keep raw as detail** — the friendly message is what the user reads, but the
   raw chain/libwallet text stays available: expandable/copyable in the UI, and
   **always** `logError()`'d for the developer (see [Log user errors] memory).
3. **Central error handler** — one utility every screen routes through, replacing
   the ~5 divergent ad-hoc implementations.

*Out of scope for v1 (future enhancement):* fully actionable errors with buttons
(Retry / Top up SOL / Adjust slippage). The design leaves room for it (§6.4) but
v1 ships message + raw detail only.

---

## 3. How errors reach us (Go → FFI → Dart)

### 3.1 Transport

```
chain / RPC / aggregator
   │  raw error string
   ▼
Go libwallet (wltswap, wlttx, wltnet, wltacct, …)
   │  errors.New / fmt.Errorf / forwarded verbatim
   ▼
cshared/ffi.go  →  {"result":"error","error":"<msg>","code":<n>,"status":"<tok>"}
   ▼
dart ffi_transport.dart  →  LibwalletResponse
   ▼
throws  LibwalletException
```

### 3.2 The Dart exception shape (verified)

`libwallet/dart/lib/src/client/response.dart:43`

```dart
class LibwalletException implements Exception {
  final String message;   // resp.error   — the human/raw text (OFTEN carries the real reason)
  final String code;      // resp.code    — stringified transport/RPC code ("400","500","503","4001",...)
  final String? token;    // resp.status  — occasional status token
  String toString() => 'LibwalletException($code): $message';
}
```

### 3.3 ⚠️ Two facts that dictate the whole design

**Fact A — the useful discriminator is usually in `.message`, not `.code`.**
`.code` is typically the FFI transport code (`400` bad request, `500` internal,
`503` shutting down) or an apirouter/JSON-RPC code (`4001` user-rejected,
`4902` unknown chain, `-32602` invalid params). But the *domain* reason —
`token_expired`, `insufficient`, `Blockhash not found`, `slippage` — arrives as a
**substring of `.message`**. This is exactly why the best existing helper,
`LibwalletBackend.friendlyTransferError` (`libwallet_backend.dart:2705`), matches
on `e.message.contains('token_expired')` and friends. Our central mapper must key
off **both** `.code` (when stable) **and** `.message` substrings.

**Fact B — swap *quote* errors are data, not exceptions.**
`Swap:quote` returns a list of `QuoteAttempt`, each of which may carry a typed
`SwapError` (`libwallet/dart/lib/src/models/swap_quote.dart:533`) with a **stable
`.code`** (`no_liquidity`, `slippage_exceeded`, `quote_expired`,
`provider_unavailable`, …). These are returned on a *successful* call and must be
read from the data, not caught. Swap *execution* failures, by contrast, **throw**
`LibwalletException` with the reason in `.message`. The mapper needs a small
adapter that turns a `SwapError` into the same friendly pipeline.

---

## 4. Error catalog — what we actually receive

Grouped by origin, with what's **reliably matchable** vs **fragile**. Sourced from
`libwallet/wltswap`, `wlttx`, `wltnet`, `wltacct`, `wltwallet`, `cshared/ffi.go`,
and `okx_test.go` (concrete example strings).

### 4.1 Stable — safe to branch on

| Signature | Where | Meaning | Friendly message |
|---|---|---|---|
| `code == "4001"` | apirouter (web3) | User rejected request | *(silent — user knows)* |
| `code == "4902"` | apirouter (web3) | Unknown chain ID | "This network isn't supported yet." |
| `code == "-32602"` | wltnet JSON-RPC | Invalid params / bad RPC config | "Network configuration problem." |
| `code == "503"` | ffi.go | Wallet shutting down | "Wallet is busy, try again." |
| `SwapError.code == "no_liquidity"` | wltswap/errors.go | No route for pair/size | "No swap route for this pair right now." |
| `SwapError.code == "slippage_exceeded"` | wltswap | Would settle below min out | "Price moved — try again or raise slippage." |
| `SwapError.code == "quote_expired" / "quote_not_found"` | wltswap | Re-quote needed | "Quote expired — refreshing." |
| `SwapError.code == "provider_unavailable"` | wltswap | Aggregator 5xx/timeout | "Swap service is unavailable, try again." |
| `message == "wrong password"` (code `403`) | wltwallet/errors.go | Bad password | "Incorrect password." |

### 4.2 Stable-ish — match on `.message` substring (libwallet-generated)

These strings are generated by libwallet itself, so they change only when we change
them. Reasonable to match, but centralize so a rename is a one-line fix.

| `message` contains | Meaning | Friendly message |
|---|---|---|
| `local_offline` / `peer_unreachable` / `session_not_found` / `token_expired` / `declined` / `timeout` | device transfer (already mapped in `friendlyTransferError`) | *(reuse existing map)* |
| `amountIn is required` / `tokenIn.address ... required` / `nil request` | swap input validation | "Something's missing from this swap." |
| `empty RPC URL` / `RPC URL must use https` / `invalid RPC URL` | wltnet URL guard | "Invalid RPC URL." |
| `wrong storeKey` | wltwallet | "Couldn't unlock — try restoring from cloud." |

### 4.3 Fragile — forwarded verbatim from chain/RPC/aggregator

**Do not branch on business logic here — match only to pick a friendly message, and
always keep the raw text as detail.** These come from Solana validators / OKX /
Jupiter and can change format between versions. (Examples from `wltswap/okx.go`
`isRetryableSolanaBroadcast` and `okx_test.go`.)

| `message` contains (case-insensitive) | Real cause | Friendly message |
|---|---|---|
| `blockhash not found` / `block height exceeded` / `expired` | stale blockhash | "Network was busy — please retry." |
| `insufficient` (e.g. `insufficient lamports`) | not enough balance/fee | "Not enough balance to cover this transaction." |
| `slippage` / `exceeds desired slippage limit` | price moved | "Price moved too much — try again." |
| `custom program error: 0x…` / `error processing instruction` | on-chain program reverted | "The transaction was rejected on-chain." + raw |
| `Failed to get quotes` / `no route` | aggregator has no route | "No swap route available right now." |
| `SocketException` / `Failed host lookup` / `Connection refused` / `timed out` | network (client-side) | "No internet connection." / "Server unavailable." |

### 4.4 Non-libwallet exceptions the UI already handles

- `FormatException` → use `.message` (backup/restore).
- `AtOnlinePlatformException` → use `.data`, not `toString()` (agents screen).
- `StateError` → `.message` is user-safe in transfer flows.
- `PairingException` (ClawdWallet) → enum-mapped in `pairing_screen.dart`.
- `ReshareStalledException` → `.toString()` is already a bare message.

The central mapper must accept `Object e` and handle these types too, so callers
never have to special-case.

---

## 5. Existing helpers (what to consolidate)

| Helper | File | What it does | Verdict |
|---|---|---|---|
| `_friendlyError(Object)` | `swap_screen.dart:65` | network-string → friendly; strips `Exception:` | Fold into central mapper |
| `_friendlyError(Object)` | `inapp_backup_restore_screen.dart:175` | `FormatException` special-case | **Duplicate** — remove |
| `friendlyTransferError(Object)` | `libwallet_backend.dart:2705` | code-in-message map, best-in-class | **Model for the new API**; keep, delegate |
| `_messageFor(PairingException)` | `pairing_screen.dart:74` | enum → (title, body) | Keep (domain-specific), but route display through central widget |
| `logError(msg,[e,st])` | `utils/log.dart:22` | debug-only `debugPrint` | **Reuse everywhere** — mapper calls it |
| `wallet.libwallet.error` | `libwallet_backend.dart:154` | backend error state string | Populate via mapper so it's already friendly |

---

## 6. Proposed design

### 6.1 A single mapper: `WalletError`

New file `lib/utils/wallet_error.dart`:

```dart
/// A user-facing error with the raw detail preserved for debugging.
class WalletError {
  final String message;        // friendly, shown to the user
  final String raw;            // original text (chain/libwallet) — expandable + copyable
  final String? code;          // stable code when we have one (for tests / future actions)
  final bool silent;           // true => don't surface (e.g. user-rejected 4001)

  const WalletError({required this.message, required this.raw, this.code, this.silent = false});

  /// The single entry point. Accepts anything a catch block produces.
  factory WalletError.from(Object e) { … }
}
```

`WalletError.from` order of resolution (first match wins):

1. `SwapError`  → branch on stable `.code` (Fact B).
2. `LibwalletException` → branch on `.code` (§4.1), then `.message` substrings (§4.2/§4.3).
3. Known Dart types → `FormatException`, `AtOnlinePlatformException`, `StateError`,
   `PairingException`, `ReshareStalledException` (§4.4).
4. Generic network strings (§4.3 last row) — subsumes both `_friendlyError`s.
5. Fallback → `message = raw.replaceFirst('Exception: ', '')`, `raw = e.toString()`.

`WalletError.from` is **pure** (no logging, no side effects) so it stays trivially
unit-testable and idempotent across widget rebuilds. Logging happens at the
**display boundary** instead: the Phase 2 helpers (`showWalletError` /
`walletErrorCard`) call `logError('[WalletError] ${we.code}', e)` with the raw
detail whenever an error is actually surfaced ([Log user errors] memory satisfied —
"whenever an error is shown to the user, also debugPrint it").

The message table lives as a `const` list of `(matcher, code, message)` rules so
adding/renaming a mapping is a one-liner and is trivially unit-testable.

### 6.2 A single display path

Add two thin helpers so screens stop hand-rolling `SnackBar`/inline `Text`:

```dart
// SnackBar with a "Details" action that opens a copyable raw-text sheet.
void showWalletError(BuildContext, Object e);

// Inline error card for form/loading states; expandable raw detail.
Widget walletErrorCard(Object e);   // or: WalletError.from(e) → widget
```

Both call `WalletError.from(e)`, skip display when `silent`, and expose `raw`
behind a "Details" affordance (copy to clipboard). This is where "keep raw as
detail" is realized in the UI.

### 6.3 Migration — route every site through the mapper

Replace `Text('… $e')` / `Text(e.toString())` / per-screen `_friendlyError(e)`
with `showWalletError(context, e)` or `walletErrorCard(e)`. Backend `error` strings
(`wallet.libwallet.error`) should be set to `WalletError.from(e).message` at the
point they're assigned, so consumers get a friendly string without change.

### 6.4 Future hook (not v1)

`WalletError` carries `code`, so a later `action` field (`retry`, `topUpSol`,
`raiseSlippage`) can be attached per code without touching call sites.

---

## 7. Implementation phases (each ships its own unit tests)

Per [Unit tests per phase] memory, every phase includes tests in the same change.

- **Phase 1 — `WalletError` + tests.** Create `wallet_error.dart` with the rule
  table and `WalletError.from`. Unit tests feed representative raw strings/exception
  instances (from §4, incl. the `okx_test.go` examples) and assert `message`,
  `code`, `silent`, and that `raw` is preserved. No UI changes yet.
- **Phase 2 — display helpers + tests.** `showWalletError` / `walletErrorCard` with
  copyable raw detail. Widget tests assert friendly text shows, raw is reachable,
  `silent` suppresses.
- **Phase 3 — migrate high-traffic raw sites.** swap, send, incinerator, staking,
  fee-sharing (the §4.3 chain-error paths matter most here). Delete the two
  `_friendlyError` copies; delegate `friendlyTransferError` to the mapper.
- **Phase 4 — migrate remaining sites** (wallet mgmt, settings, clawdwallet,
  web3/browser, walletconnect) and set backend `error` via the mapper.

---

## 8. Appendix — every user-facing libwallet-error display site

Full inventory (file : line — mechanism — raw/friendly). "RAW" = shows `$e` /
`e.toString()` verbatim today and is a migration target. "MIXED" = shows a backend
`error` string that is itself raw from libwallet.

### Swap
- `screens/swap_screen.dart:336` — SnackBar — **RAW** (`'Switch failed: $e'`)
- `screens/swap_screen.dart:477,569,857` — inline `_error`/`_quoteError` — friendly (`_friendlyError`)
- `screens/swap_screen.dart:2018` — SnackBar — friendly (`_friendlyError`)

### Fee sharing
- `screens/fee_sharing_screen.dart:161,214,258,308,381` — SnackBar — **RAW** (`'Error: $e'`)

### Incinerator
- `screens/incinerator_screen.dart:149` — inline `_error` — **RAW** (`'Failed to load tokens: $e'`)
- `screens/incinerator_screen.dart:425,583,789` — SnackBar — **RAW** (`'Error: $e'`)
- `screens/incinerator_screen.dart:575,764` — SnackBar — **MIXED** (`wallet.error`)

### Token / About
- `screens/token_detail_screen.dart:96,214` — inline `_error` — **RAW**
- `screens/about_screen.dart:41` — version card — **RAW** (`e.toString()`)

### Staking
- `screens/staking/staking_detail_screen.dart:429,492,639` — SnackBar — **RAW**
- `screens/staking/staking_detail_screen.dart:631` — SnackBar — **MIXED** (`wallet.error`)
- `screens/staking/staking_pools_screen.dart:59` — inline `_error` — **RAW**
- `screens/staking/staking_members_screen.dart:77` — inline `_error` — **RAW**

### Wallet management
- `screens/wallet/networks_screen.dart:76` — SnackBar — **MIXED**
- `screens/wallet/wallet_details_screen.dart:242,286` — SnackBar — **MIXED**
- `screens/wallet/accounts_management_screen.dart:92,103` — SnackBar — **MIXED**
- `screens/wallet/accounts_management_screen.dart:151` — SnackBar — **RAW**
- `screens/wallet/widgets/account_switcher_sheet.dart:76` — SnackBar — **MIXED**
- `screens/wallet/tokens_screen.dart:128,153,197` — SnackBar — **RAW**
- `screens/wallet/wallets_management_screen.dart:84` — inline `_error` — **RAW**
- `screens/wallet/btc_addresses_screen.dart:70,98` — inline `_error` — **RAW**
- `screens/wallet/nfts_screen.dart:55` — inline `_error` — **RAW**

### Send
- `screens/wallet/send_screen.dart:372` — inline `_resolveError` — friendly
- `screens/wallet/send_screen.dart:394,445` — inline `_error` — **RAW** (`'… $e'`)
- `screens/wallet/send_screen.dart:486` — inline `_error` — cleaned (`replaceFirst('Exception: ','')`)

### Create / import / backup / export / migration
- `screens/wallet/inapp_create_screen.dart:125,159,216` — inline `_error` — **RAW**
- `screens/wallet/inapp_import_mnemonic_screen.dart:131,164,201` — inline `_error` — **RAW**
- `screens/wallet/inapp_backup_restore_screen.dart:160,166,167` — inline/SnackBar — friendly (`_friendlyError`)
- `screens/wallet/inapp_backup_restore_screen.dart:157` — SnackBar — **MIXED**
- `screens/wallet/inapp_export_screen.dart:82` — inline `_error` — cleaned (`replaceFirst('Bad state: ','')`)
- `screens/wallet/inapp_export_screen.dart:125,149` — AlertDialog — **RAW**
- `screens/wallet/biometric_migration_screen.dart:48` — inline `_error` — **RAW**

### Device transfer / signing
- `screens/wallet/device_transfer_send_screen.dart:141` — inline `_message` — friendly (`friendlyTransferError`)
- `screens/wallet/device_transfer_send_screen.dart:197` — inline `_message` — **RAW**
- `screens/wallet/widgets/sign_sheet.dart:124` — inline `_error` — **RAW**

### Settings — security/privacy
- `screens/settings/security_privacy_screen.dart:174,204,248,272,346,376` — SnackBar — **MIXED** (`wallet.libwallet.error ?? fallback`)

### ClawdWallet
- `screens/clawdwallet/agents_screen.dart:85` — inline `_error` — MIXED (`AtOnlinePlatformException.data` else `toString`)
- `screens/clawdwallet/agents_screen.dart:131` — SnackBar — **RAW**
- `screens/clawdwallet/pairing_screen.dart:58,59` — inline — friendly (`_messageFor`)
- `screens/clawdwallet/pairing_screen.dart:67` — inline — **RAW** (unexpected fallback)
- `screens/clawdwallet/activity_screen.dart:63` — inline `_error` — **RAW**
- `screens/clawdwallet/create_agent_wallet_screen.dart:147` — inline `_error` — **RAW**

### Contacts / Web3 / WalletConnect / Browser
- `screens/contacts/contacts_screen.dart:113` — SnackBar — **RAW**
- `screens/web3_connections_screen.dart:101` — SnackBar — **RAW**
- `screens/walletconnect/walletconnect_sessions_screen.dart:87` — SnackBar — **MIXED** (`bridge.error`)
- `screens/browser/dapp_browser_view.dart:179-185` — JSON-RPC response to webview — MIXED (`LibwalletException.code`+`.message`, else `toString`)

**Totals:** ~75 sites. ~40% pass raw `$e`; ~35% show a backend `error` string that
is itself raw libwallet text (MIXED); ~20% already do some friendly mapping via one
of the four helpers being consolidated.

---

## 9. Key file references

- Dart exception: `libwallet/dart/lib/src/client/response.dart:43`
- FFI error serialization: `libwallet/cshared/ffi.go` (codes 400/500/503)
- Swap typed errors: `libwallet/wltswap/errors.go`; Dart model
  `libwallet/dart/lib/src/models/swap_quote.dart:533`
- Solana broadcast error matching (source of §4.3 strings):
  `libwallet/wltswap/okx.go` (`isRetryableSolanaBroadcast`) + `okx_test.go`
- Password errors: `libwallet/wltwallet/errors.go`
- Best existing helper (model for new API): `libwallet_backend.dart:2705`
- Debug logging: `lib/utils/log.dart:22`
