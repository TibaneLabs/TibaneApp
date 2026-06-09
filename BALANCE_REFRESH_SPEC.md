# Balance / Token-List Refresh — Reference & Gaps

How the wallet UI keeps balances, the token list, and wallet content fresh
after a state-changing action (send, swap, stake, burn, switch, dApp tx, …),
and the four known gaps where the refresh is **delayed** rather than immediate.

> All gaps below are about **immediacy**, not permanent staleness: libwallet's
> background poller (~60 s) eventually reconciles everything. The gaps matter
> for the moment right after an action, when the user expects to see the result.

---

## 1. Architecture

There are **two data layers** that can go stale, refreshed by **two trigger
sources**.

### Data layers

| Layer | Lives in | Refreshed by | Reads from |
|---|---|---|---|
| **Headline balances** (SOL, ChiefPussy, fiat) | `WalletService` | `refreshBalances()` — `wallet_service.dart:307` | libwallet `getAssets()` |
| **Dashboard token list** (`_assets`, every token row) | `WalletDashboard` widget | its own `_loadData()` — `wallet_dashboard.dart:97` | libwallet `getAssets()` |

**Critical distinction:** `refreshBalances()` updates the headline **only**. It
does **not** reload the dashboard token list. The token list reloads only via
`_loadData()`, which is triggered by `swapCommittedTick`, a `txHistoryUpdates`
event, or pull-to-refresh.

### Trigger sources

**App-driven (immediate)** — an action explicitly calls one of:
- `refreshBalances()` — headline only.
- `notifyTxCommitted()` — `wallet_service.dart:209` → bumps `swapCommittedTick`
  **and** calls `refreshBalances()`. This is the only app call that refreshes
  **both** layers (the `swapCommittedTick` listener at `wallet_dashboard.dart:54`
  → `_onTxCommitted` `:62` → `_loadData`).
- a screen-local reload (`_loadTokens()`, `_loadAll()`, `_loadUserStake()`,
  `_load()`) that only refreshes that screen's own list.

**libwallet-driven (reactive safety net, ~60 s poller or on libwallet's own send)**:
- `balanceChanges` event → backend `balanceTick++` (`libwallet_backend.dart:376`)
  → `WalletService._onBalanceTick` (`wallet_service.dart:427`) → `refreshBalances()`
  (headline).
- `txHistoryUpdates` event → dashboard subscription (`wallet_dashboard.dart:76`)
  → `_loadData()` (token list).

On a wallet/account switch, `_onBackendChanged` (`wallet_service.dart:410`)
detects the address change and calls `resetSessionState()`
(`wallet_service.dart:161`) which **zeros** the headline balances; the fresh
values come from a subsequent `refreshBalances()` (e.g. via `useLibwallet()`)
or the next `balanceTick`.

### Rule of thumb

> To refresh **both** layers immediately after an action, call
> `wallet.notifyTxCommitted()`. Calling only `refreshBalances()` leaves the
> dashboard token list stale until the libwallet poller / tx-history event fires.

---

## 2. Per-action reference

| Action | Site | App refresh | Headline | Token list | Notes |
|---|---|---|---|---|---|
| **Swap** | `swap_screen.dart:649` | `notifyTxCommitted()` + `_loadHoldings()` + 4 s/10 s re-polls | ✅ now | ✅ now | Gold-standard path |
| **Send SOL/SPL** | `send_screen.dart:314` | `refreshBalances()` **only** | ✅ now | ⚠️ delayed | **Gap 1** |
| **Burn** (3 paths) | `incinerator_screen.dart:409/578/783` | `_loadTokens`/`_loadAll` + `refreshBalances()` | ✅ | own ✅ / dashboard ⏳ | **Gap 3** |
| **Stake/unstake/claim** | `staking_detail_screen.dart:417/465/607` | `_loadUserStake` + `refreshBalances()` | ✅ | own ✅ / dashboard ⏳ | **Gap 3** |
| **Add/remove token** | `tokens_screen.dart:118/146/190` | `_load()` (own) | — | own ✅ / dashboard ⏳ | **Gap 3** |
| **Switch account** | `accounts_management_screen.dart:105` | `refreshBalances()` | ✅ | ⏳ | List via new-account tx-history |
| **Switch wallet** ("Use this wallet") | `inapp_unlock_screen.dart:150/170/225` | `useLibwallet()` → `refreshBalances()` | ✅ (after zeroing) | ⏳ | `_onBackendChanged` zeros first |
| **Create wallet** | `inapp_create_screen.dart:183` | `useLibwallet()` → `refreshBalances()` | ✅ | ⏳ | |
| **Device-transfer receive — "switch to it"** | `device_transfer_receive_screen.dart` | `useLibwallet()` → `refreshBalances()` | ✅ | ⏳ | |
| **Device-transfer receive — "keep current"** | — | none | n/a | n/a | Correct: received wallet isn't shown |
| **Import mnemonic** | `inapp_import_mnemonic_screen.dart:130` | none | n/a | n/a | Wallet not activated; wallets-list reloads on return |
| **Remove wallet** | `wallet_details_screen.dart:199` | `refreshBalances()` | ✅ | list reloads on return | |
| **Disconnect** | `wallet_service.dart:142` | `resetSessionState()` + `notifyListeners()` | ✅ (zeroed) | — | |
| **Network switch** | `networks_screen.dart` | `refreshBalances()` | ✅ | ⏳ | |
| **dApp / WalletConnect / browser tx** | `libwallet_request_bridge.dart:105` | **none** | ⏳ | ⏳ | **Gap 2** |

Legend: ✅ now = immediate · ⏳ = via libwallet poller / tx-history event
(~60 s) or pull-to-refresh · ⚠️ = gap.

---

## 3. Gaps

### Gap 1 — Send doesn't reload the dashboard token list

- **Where:** `send_screen.dart:314` — on a successful broadcast it calls
  `wallet.refreshBalances();` (headline only), then shows the success modal and
  pops.
- **Symptom:** after sending an **SPL token** (e.g. USDT), the headline SOL
  updates immediately, but that token's **row in the dashboard token list lags**
  until libwallet's `txHistoryUpdates` / `balanceChanges` event fires (or the
  user pull-to-refreshes). Native SOL sends look fine because SOL *is* the
  headline.
- **Cause:** the dashboard token list reloads only on `swapCommittedTick` /
  `txHistoryUpdates`; `refreshBalances()` bumps neither.
- **Inconsistency:** Swap (`swap_screen.dart:649`) does this correctly via
  `notifyTxCommitted()`.
- **Fix:** in `send_screen.dart`, replace `wallet.refreshBalances();` with
  `wallet.notifyTxCommitted();` (which refreshes the headline **and** bumps
  `swapCommittedTick` so the dashboard reloads its token list).

### Gap 2 — dApp / WalletConnect / browser transactions get no app-side refresh

- **Where:** `libwallet_request_bridge.dart:105` — after
  `await client.requests.approve(req.id, keys: keys);` there is no
  `refreshBalances()` / `notifyTxCommitted()`.
- **Symptom:** a transaction approved from a dApp (WalletConnect or the in-app
  browser) changes balances, but neither the headline nor the token list updates
  until the libwallet poller (~60 s) catches it.
- **Cause:** the bridge only signs/submits; nothing notifies `WalletService`.
- **Fix:** after a successful **transaction-type** `approve` (not message-sign /
  add-network / chain-switch), call `wallet.notifyTxCommitted()`. Message-sign
  needs nothing (no on-chain change). Chain-switch already routes through
  `_onBackendChanged` for the network change but may still show stale balances
  until the next refresh — consider a `refreshBalances()` there too.

### Gap 3 — Burn / stake / token-CRUD refresh their own screen but not the dashboard

- **Where:** `incinerator_screen.dart:409/578/783`,
  `staking_detail_screen.dart:417/465/607`,
  `tokens_screen.dart:118/146/190`.
- **Symptom:** these correctly reload their own list (`_loadTokens`/`_loadAll` /
  `_loadUserStake` / `_load`) and call `refreshBalances()` (headline), but the
  **dashboard** token list isn't bumped, so on return it can be briefly stale.
- **Severity:** low — the user is on the action screen (which *is* fresh) during
  the action, and the dashboard self-heals via the poller / tx-history event.
- **Fix (optional):** call `notifyTxCommitted()` instead of `refreshBalances()`
  in these success paths so the dashboard is also current on return. Lower
  priority than Gaps 1–2.

### Gap 4 — Lifecycle is not reported, so resume-from-background doesn't fast-refresh

- **Where:** the app never calls `client.lifecycle.update(...)` except inside
  the device-transfer screens.
- **Symptom:** libwallet's poller has a "poll immediately on app resume from
  background" optimization that's gated on the host reporting lifecycle state.
  Because the app doesn't report `foreground`/`resumed`, after returning from
  background the balances can stay stale for up to the full ~60 s poll interval.
- **Severity:** low–medium — only affects the first up-to-60 s after a cold
  resume; normal in-app actions are unaffected (the poller runs continuously
  because the app also never reports `background`, so it's never paused).
- **Fix (optional):** add an app-wide `WidgetsBindingObserver` that calls
  `client.lifecycle.update('foreground')` / `'background'` on
  `didChangeAppLifecycleState`. This also lets libwallet pause the poller while
  backgrounded (battery) and resume-poll on foreground. Doing it app-wide would
  also let us drop the one-off `lifecycle.update('foreground')` calls currently
  inside the device-transfer screens.

---

## 4. Recommended priority

1. **Gap 1** (send → `notifyTxCommitted`) — small, safe, removes the most
   user-visible inconsistency (sent SPL token balance not updating).
2. **Gap 2** (dApp tx → `notifyTxCommitted`) — small, safe.
3. **Gap 4** (app-wide lifecycle reporting) — modest, also improves battery and
   lets the device-transfer screens stop reporting foreground themselves.
4. **Gap 3** (burn/stake/token-CRUD → `notifyTxCommitted`) — lowest; cosmetic
   dashboard freshness on return.

---

## 5. Key code references

| Symbol | Location |
|---|---|
| `refreshBalances()` (headline; reads `getAssets()`) | `lib/services/wallet_service.dart:307` |
| `notifyTxCommitted()` (headline + `swapCommittedTick`) | `lib/services/wallet_service.dart:209` |
| `resetSessionState()` (zeros headline) | `lib/services/wallet_service.dart:161` |
| `_onBalanceTick()` (libwallet → headline) | `lib/services/wallet_service.dart:427` |
| `_onBackendChanged()` (switch → reset) | `lib/services/wallet_service.dart:410` |
| `balanceChanges` → `balanceTick++` | `lib/services/wallet/libwallet_backend.dart:376` |
| dashboard `_loadData()` (token list) | `lib/screens/wallet/wallet_dashboard.dart:97` |
| dashboard `swapCommittedTick` listener | `lib/screens/wallet/wallet_dashboard.dart:54` |
| dashboard `txHistoryUpdates` listener | `lib/screens/wallet/wallet_dashboard.dart:76` |
