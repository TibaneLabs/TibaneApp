# Balances Store Migration — one centralized `BalancesStore`

**Status:** Phase 1a done (store created + dashboard converted), uncommitted pending device validation. Phase 1b (send + swap) next.

> **Progress:** `lib/services/balances_store.dart` (new) owns the Jupiter SPL
> holdings + tx list + reload/listeners; provided in `main.dart`; the dashboard
> is now a pure consumer (`context.watch<BalancesStore>()`, `store.refresh()`) —
> its `JupiterService`/`_holdings`/`_loadData`/listeners deleted. Reload
> coalescing extracted to `lib/utils/coalescer.dart` (unit-tested). `analyze`
> clean; all existing tests green. **Still on the store's own JupiterService
> only** — send/swap keep their own until Phase 1b, and `_assets` stays on
> `WalletService` until Phase 2. Full store unit tests await a `WalletService`
> fake (the store takes the concrete service today — see §3e / Phase 2 DI).
**Goal:** One store owns all balance/holdings/transaction data + every listener,
stream, and refresh path. Screens become pure consumers. Kills the class of bug
where one screen is wired to a refresh trigger and another isn't (e.g. the
dashboard's USDT row not reloading on the balance poller).
**Mechanism (decided, D1):** `BalancesStore extends ChangeNotifier`, provided via
`provider` — consistent with the app's existing state layer (`WalletService`,
`FavoritesService`, `BrowserPreferences`, `UkComplianceService`). No `flutter_bloc`.
**Builds on:** BALANCE_REFRESH_SPEC.md (the refresh mechanics this centralizes).

---

## 1. Why

Refresh logic is fragmented across `WalletService` **and** each screen:

- `WalletService` owns the libwallet-derived balances (`_assets`) + the
  `notifyTxCommitted`/`confirmAndRefresh`/`refreshBalances` machinery.
- But **each screen separately** `new`s a `JupiterService`, holds its own
  `_holdings` (the Solana SPL list), and re-implements its own reload triggers.

So the Jupiter SPL rows on the dashboard were reloaded only on mount / tx-commit,
never by the 60s balance poller — the USDT-stays-stale bug. Any new screen
repeats the same wiring and the same risk. Centralizing makes "how balances
refresh" exist in exactly one place.

---

## 2. Current architecture (as-is) — the fragmentation inventory

### 2a. Refresh machinery in `WalletService` (`lib/services/wallet_service.dart`)
| Piece | Role |
|---|---|
| `_assets` (`List<Asset>`) | Single source for native + tracked-token balances + fiat |
| `refreshBalances()` / `_refreshBalancesOnce()` | Reload `_assets` from libwallet `getAssets()` (in-app) or RPC (MWA); coalesced |
| `_refreshFresh()` | invalidate libwallet asset cache → `refreshBalances()` |
| `notifyTxCommitted()` / `_refreshAfterTx()` | Immediate + 3s/9s re-polls; bumps `swapCommittedTick`; `kickHistoryBackfill()` |
| `confirmAndRefresh(hash)` | Solana confirm → adaptive reload until balance moves |
| `notifyTokenListChanged()` | Single refresh for local token-table edits |
| `swapCommittedTick` (`ValueNotifier<int>`) | Fan-out signal to screens to reload |
| `discoverHoldings()` | RPC scan → register missing SPL mints |
| `_onBalanceTick()` | libwallet `balanceTick` listener → `refreshBalances()` |
| `reportLifecycle()` | foreground/background → libwallet poller |
| `_txCacheByAddress` + `cachedTxsFor`/`cacheTxsFor` | Per-address tx cache |
| `solBalance` / `chiefPussyBalance` / fiat getters | Derived headline reads |

### 2b. Per-screen duplication (the part to collapse first)
| Screen | Own `JupiterService` | Own holdings/tx state | Own refresh trigger |
|---|---|---|---|
| `wallet/wallet_dashboard.dart` | `:38` | `_holdings` `:32`, `_transactions`, `_loadData`/`_loadDataOnce`, `_kickedHistoryBackfill` | listens `swapCommittedTick` + `balanceTick` + `txHistoryUpdates`; coalescing guard |
| `wallet/send_screen.dart` | `:71` | `_holdings`, `_loadHoldings` (`fetchHoldings` `:150`) | `notifyTxCommitted` + `confirmAndRefresh` on send |
| `swap_screen.dart` | `:82` | holdings via `_loadHoldings` (`fetchHoldings` `:428`) | `TxConfirmationRefresh` mixin (`:81`) + `swapCommittedTick` listener |
| `token_detail_screen.dart` | `:110` | one-off `fetchTokenPrices([mint])` `:112` | — |

### 2c. The `TxConfirmationRefresh` mixin (`lib/services/tx_confirmation.dart`)
`kTxConfirmationDelays = [3s, 9s]` + a mixin that re-runs a screen's own reload at
those offsets. Users: `swap_screen.dart:81` (`refreshAfterTx(_loadHoldings)` `:820`),
`staking/staking_detail_screen.dart:34` (`refreshAfterTx(_loadUserStake)` `:435`).
Note staking reloads **pool-specific** on-chain data, not balances — see §7.

### 2d. Refresh-trigger callers (`onTxCommitted`-shaped) — must all route to the store
`notifyTxCommitted` / `notifyTokenListChanged` / `refreshBalances` are called from:
`send_screen`, `swap_screen`, `incinerator_screen`, `staking/staking_detail_screen`,
`browser/dapp_browser_view` (`onTxCommitted:`), `wallet/tokens_screen`,
`wallet/networks_screen`, `wallet/accounts_management_screen`,
`wallet/wallet_details_screen`, plus `wallet/libwallet_request_bridge.dart` (dApp/WC).

### 2e. Consumers (reads)
`wallet_dashboard` (assets + holdings + transactions + totals), `wallet_button`
(headline), `token_detail` (price), `swap_screen` / `send_screen` (holdings +
balances). Screenshot harness (`screenshot_main.dart`) also reads.

---

## 3. Target: `BalancesStore extends ChangeNotifier`

**One instance, provided at the app root** (next to `WalletService` in
`main.dart`'s `MultiProvider`). Depends on `WalletService` for wallet identity
(active address, libwallet client, in-app vs MWA) and reacts to it.

### 3a. Owns (state)
- `assets` — native + tracked tokens (libwallet), with fiat.
- `holdings` — the Solana SPL list (Jupiter), merged/deduped with tracked assets.
- `transactions` — per active address, with the address-scoped cache.
- `prices` — per-mint USD (Jupiter price API), incl. single-token lookups.
- `totalUsd`, `solBalance`, native/native-symbol, `loading`, `error`, `lastRefresh`.

### 3b. Subscribes (once, internally)
- libwallet `balanceTick` (poller / tx-broadcast nudge) → refresh.
- libwallet `txHistoryUpdates` → reload transactions.
- `WalletService` changes (address/account/network switch) → reset + reload.
- app lifecycle is already reported by `WalletService.reportLifecycle`; the store
  just benefits from the poller resuming.

### 3c. Owns (refresh system — moved out of screens + WalletService)
- initial load, poller-driven refresh, **coalescing/debounce** (the dashboard's
  `_loadInFlight`/`_loadQueued` becomes the store's), one `JupiterService`.
- `onTxCommitted(hash)` — the merged `notifyTxCommitted` + `confirmAndRefresh`
  (immediate + 3s/9s + adaptive confirm loop), cache invalidation, discovery,
  history backfill.
- `refresh()` — the pull-to-refresh path (invalidate + discover + backfill + reload).

### 3d. Exposes (consumption API)
- Reactive reads (via `context.watch<BalancesStore>()`): `holdings`, `assets`,
  `transactions`, `solBalance`, `totalUsd`, `priceFor(mint)`, `loading`.
- Imperative: `onTxCommitted(hash)`, `refresh()`.
- `txCommitted` (a `Listenable`) for screens that must reload their **own**
  derived data after a tx (e.g. staking pool state) — replaces the mixin's timers.

### 3e. Dependency injection (for testability — the big win)
Constructor takes the libwallet backend, a `JupiterService`, and an `RpcService`
factory (today these are `new`'d inline, so nothing is unit-testable). With them
injected, the store's refresh logic — adaptive confirm loop, coalescing, poller
wiring, MWA fallback — becomes unit-testable with fakes. See §8.

---

## 4. What each screen becomes (consumer-only)

- **Dashboard:** delete `JupiterService`, `_holdings`, `_transactions`,
  `_loadData`/`_loadDataOnce`, the three listeners, `_kickedHistoryBackfill`, the
  coalescing flags. Read `store.holdings` / `store.transactions` /
  `store.totalUsd`; pull-to-refresh → `store.refresh()`.
- **Send:** delete `JupiterService` + `_holdings` + `_loadHoldings`; read
  `store.holdings`; after send → `store.onTxCommitted(tx.hash)`. (The send USD
  estimate — `holdingUnitPriceUsd`/`_nativePriceUsd` — reads `store.priceFor`.)
- **Swap:** delete `JupiterService` + `_loadHoldings` + `TxConfirmationRefresh`;
  read `store.holdings`; after swap → `store.onTxCommitted(hash)`.
- **Token detail:** `store.priceFor(mint)` instead of a one-off `fetchTokenPrices`.
- **Incinerator / dApp bridge / tokens / networks / accounts / wallet-details:**
  swap `wallet.notifyTxCommitted()` → `store.onTxCommitted(hash)` (or
  `store.refresh()` for the non-tx list-changed cases).

---

## 5. Relationship to `WalletService` (what moves, what stays)

**Moves out of `WalletService` into `BalancesStore`:** `_assets`,
`refreshBalances`/`_refreshBalancesOnce`/`_refreshFresh`, `notifyTxCommitted`/
`_refreshAfterTx`/`notifyTokenListChanged`, `confirmAndRefresh`,
`swapCommittedTick` (→ becomes the store's internal notify), `discoverHoldings`,
`_onBalanceTick`, `_txCacheByAddress`+`cachedTxsFor`/`cacheTxsFor`, the
`solBalance`/`chiefPussyBalance`/fiat getters.

**Stays in `WalletService`:** wallet identity/lifecycle — backends (MWA/in-app),
active account/address, auth/session, `reportLifecycle`, network selection,
connect/switch. The store *reads* these and resets on change.

> `WalletService` shrinks to "who is the wallet"; `BalancesStore` is "what does it
> hold + how fresh." Screens that only need balances stop depending on
> `WalletService` at all.

---

## 6. Phased rollout (de-risked)

**Phase 1 — collapse the per-screen Jupiter duplication (fixes the bug class).**
Create `BalancesStore`; move the Jupiter `holdings` + `transactions` + their
reload/coalescing/listeners into it. Dashboard/send/swap consume `store.holdings`
+ `store.transactions` and drop their `JupiterService`/`_holdings`/`_loadData`.
Store subscribes to `balanceTick` + `txHistoryUpdates` itself. `WalletService`
keeps `_assets` for now; the store reads it for native/tracked balances. Ship
with unit tests for the store.

**Phase 2 — move the balance machinery out of `WalletService`.** Relocate
`_assets` + `refreshBalances` + `notifyTxCommitted` + `confirmAndRefresh` +
`discoverHoldings` + tx cache into the store. Repoint every §2d caller to
`store.onTxCommitted`/`store.refresh`. `WalletService` shrinks per §5.

**Phase 3 — delete the mixin + final cleanup.** Remove `TxConfirmationRefresh`;
swap uses reactive reads; staking subscribes to `store.txCommitted` for its
pool-specific reload. Delete now-dead `tx_confirmation.dart` bits.

Each phase compiles, ships its own tests, and is independently device-verifiable.

---

## 7. Edge cases & gotchas
- **MWA vs in-app:** the store must keep both paths (libwallet `getAssets` vs
  direct RPC), as `WalletService` does today. Invalidate is in-app-only.
- **Account / network switch:** store must reset (zero balances, clear holdings,
  swap the address-scoped tx cache) and reload — today `resetSessionState` does
  the zeroing. Drive this off a `WalletService` listener.
- **Staking pool data is NOT balances:** `staking_detail`'s `refreshAfterTx`
  reloads `_loadUserStake` (on-chain pool state). Keep a thin per-screen reload,
  but trigger it from `store.txCommitted` instead of the mixin's own timers.
- **Swap "from = native" defaults + SOL-first ordering:** the store's `holdings`
  must be shaped so swap/send keep their native-first behavior.
- **Screenshot harness** (`screenshot_main.dart`) reads balances — provide the
  store there too, seeded deterministically.
- **`chiefPussyBalance` + `ensureChiefPussyTracked`** special-casing must move
  with `_assets`.

---

## 8. Testing (the payoff)
Today the refresh logic lives in widgets + a mock-less `WalletService`, so it's
effectively untested (see the nav work — full-shell widget tests can't even get
past the startup gate). A `ChangeNotifier` store with injected libwallet /
Jupiter / RPC fakes is directly unit-testable:
- `onTxCommitted` runs immediate + delayed refreshes and stops the adaptive loop
  when the balance moves.
- `balanceTick` triggers a holdings reload (the USDT regression, locked).
- coalescing: overlapping triggers collapse to one + one catch-up.
- account switch resets balances and reloads.
- MWA path uses RPC, in-app uses libwallet + cache invalidation.
Keep the existing pure helpers (`shouldRpcConfirm`, etc.) and their tests.

---

## 9. Risk & rollback
- **Blast radius:** every balance/holdings/tx read + refresh trigger. Mitigated by
  the phased plan — Phase 1 is additive (store alongside the current code) and
  already fixes the reported bug; Phases 2–3 remove the old paths once green.
- **Two sources of truth during Phase 1:** the store owns Jupiter holdings while
  `WalletService` still owns `_assets`. Acceptable transitional; Phase 2 unifies.
- **Rollback:** Phase 1 is contained to the store + 3 screens; revert those.
- **Do not commit** a phase until it's device-validated (project rule).

---

## 10. Decision log
- **D1 — mechanism = `ChangeNotifier` store** (chosen over `flutter_bloc` Cubit and
  over extending `WalletService`). Rationale: matches the app's uniform
  provider/ChangeNotifier layer; no new dependency; no second state paradigm.
  ("Cubit" was the user's word for the concept — centralized reactive store —
  realized here as a ChangeNotifier.)
- **D2 (proposed) — new `BalancesStore` class, not folded into `WalletService`.**
  Keeps identity vs. balances separated (§5). Confirm before Phase 2.
- **D3 (open) — Phase 1 scope:** holdings + transactions first (recommended), or
  go straight to moving `_assets` too. Recommend the smaller Phase 1.
