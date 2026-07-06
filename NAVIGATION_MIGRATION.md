# Navigation Migration — Persistent Bottom Nav (per-tab nested Navigators)

**Status:** ✅ Implemented — pending on-device validation (do not commit until validated)
**Goal:** Keep the bottom navigation bar visible on the Swap screen — and, as a
consequence of doing it the idiomatic way, on *every* pushed detail screen.
**Chosen approach:** Option B — per-tab nested `Navigator`s (see decision log).
**Branch:** `swap-menu`

> **What shipped (see §11 for detail):** `lib/widgets/tibane_app_bar.dart` (new,
> extracted branded AppBar) + a rewritten `TibaneShell` in `lib/main.dart`
> (per-tab Navigators, persistent bottom nav, `PopScope` back routing,
> keyboard-aware nav hide, `_WalletOrSwapTab`, `_BrowserTab`, pure helpers
> `shellBackAction`/`browserTabState`) + `test/navigation_shell_test.dart` (8
> tests, green). `flutter analyze` clean; full suite 202 pass / 1 pre-existing
> fail. **The 44 push sites were NOT touched** — they auto-migrate as predicted.

---

## 1. Why

Today, tapping **Swap** from the Wallet tab (and from Token/Staking detail
screens) does a `Navigator.push` on the **root** navigator. The root navigator
sits *above* the shell that owns the bottom nav, so the pushed route covers the
whole screen and the bottom nav disappears. The user wants the bottom nav to
stay reachable while on Swap.

The clean fix is to give each bottom-nav tab its **own** `Navigator`. Pushes
then happen *inside* the active tab, below the persistent bottom nav. This is the
standard Flutter "persistent bottom navigation" pattern and fixes the problem for
**all** detail screens at once, not just Swap.

---

## 2. Current architecture (as-is)

### Shell
- **File:** `lib/main.dart`
- **Widget:** `TibaneShell` / `TibaneShellState` (lines 97–325)
- **Structure:** a single `Scaffold` with:
  - **One shared branded `AppBar`** (lines 243–263): `CatLogo` + "Tibane" title +
    `NetworkChip` + `WalletButton`. This AppBar is shown over **all four tabs**.
  - **body:** `IndexedStack` (lines 264–281) holding the 4 tab bodies — all four
    stay mounted; `_currentIndex` selects which is visible.
  - **`BottomNavigationBar`** (lines 282–322): 4 items, `onTap: _navigateTo`.
- **Root navigator key:** `rootNavigatorKey` (line 48), wired into `MaterialApp`
  (line 80). Used by deep links (line 188–192) and WalletConnect.
- **Public API to preserve:** `TibaneShellState.navigateTo(int)` (line 204,
  used by the screenshot harness) and the `initialIndex` / `forceSeeker`
  constructor params (lines 100–106).

### The four tabs (IndexedStack children, `lib/main.dart:266–279`)
| Idx | Widget | Own Scaffold/AppBar? | Notes |
|-----|--------|----------------------|-------|
| 0 | `HomeScreen(onNavigate: _navigateTo)` | **No** — relies on shell AppBar | `onNavigate` switches tabs (e.g. Home→Swap) |
| 1 | `SwapScreen(initialInputMint: wsolMint)` **or** `WalletScreen()` | **No** — relies on shell AppBar | Picked by `showSwap` (MWA account & !UK) |
| 2 | `DAppBrowserScreen(active: _currentIndex == 2)` | **No** — returns a `Column`, relies on shell Scaffold/AppBar | Lazy: built only after first visit (`_browserVisited`); webview paused when `active == false` |
| 3 | `SettingsScreen()` | **No** — relies on shell AppBar; routes into sub-screens that DO have their own Scaffold+AppBar | |

Key point: **tab roots have no chrome of their own** — the shell AppBar is their
only AppBar. Every **pushed** screen, by contrast, wraps itself in its own
`Scaffold` + `AppBar` (with a back button). Example — the current pushed Swap
(`wallet_dashboard.dart:631`):
```dart
Navigator.of(context).push(MaterialPageRoute(
  builder: (_) => Scaffold(
    backgroundColor: TibaneColors.black,
    appBar: AppBar(title: const Text('Swap')),
    body: SwapScreen(initialInputMint: inputMint ?? wsolMint, ...),
  ),
));
```

### `showSwap` derivation (`lib/main.dart:238–240`)
```dart
final isUk = context.watch<UkComplianceService>().isUk;
final showSwap =
    (widget.forceSeeker ?? (wallet.currentAccount?.isMwa ?? false)) && !isUk;
```
Drives BOTH the tab-1 body (Swap vs Wallet) AND the bottom-nav item 1 label/icon
(Swap vs Wallet). Switching accounts flips the whole mode.

---

## 3. Full navigation inventory — every path must be preserved

There are **44** route-creating `push` sites plus many `pop`s. The migration must
not silently drop any. They fall into three buckets:

### Bucket A — In-tab pushes (auto-migrate, ZERO code changes)
These use `Navigator.of(context).push(...)` / `Navigator.push(context, ...)`.
`Navigator.of(context)` resolves to the **nearest** navigator, so once each tab
has its own nested `Navigator`, these automatically push *inside* the tab and the
bottom nav stays visible. **No edits required at these sites.**

| File | Line(s) | Pushes |
|------|---------|--------|
| `screens/home_screen.dart` | 139, 159, 185 | Incinerator, Staking pools, (+1) |
| `screens/settings_screen.dart` | 49, 58, 67, 76, 85, 94, 196 | Settings sub-screens |
| `screens/settings/connections_screen.dart` | 29, 40, 51 | |
| `screens/settings/wallets_accounts_screen.dart` | 35, 46, 57, 68, 77, 86, 95, 104, 113 | |
| `screens/settings/general_screen.dart` | 31 | |
| `screens/settings/security_privacy_screen.dart` | 93, 287 | (note :146 is a root pop — Bucket C) |
| `screens/token_detail_screen.dart` | 280, 347, 493, 511 | incl. **Swap** (511) |
| `screens/token_favorites_screen.dart` | 32 | |
| `screens/staking/staking_pools_screen.dart` | 289 | |
| `screens/staking/staking_detail_screen.dart` | 156, 303 | incl. **Swap** (156) |
| `screens/wallet/wallet_screen.dart` | 28 | Create wallet |
| `screens/wallet/wallet_dashboard.dart` | 246, 255, 329, **631** | 631 = `_openSwap` — **Swap** |
| `screens/wallet/wallet_details_screen.dart` | 111, 121, 138 | |
| `screens/wallet/wallets_management_screen.dart` | 91, 113, 188 | |
| `screens/wallet/nfts_screen.dart` | 139 | |
| `screens/wallet/inapp_import_screen.dart` | 18 | |
| `screens/wallet/inapp_backup_restore_screen.dart` | 144 | |
| `screens/wallet/inapp_create_screen.dart` | 309 | |
| `screens/wallet/accounts_management_screen.dart` | 168 | |
| `screens/wallet/widgets/authorize_and_sign.dart` | 43 | |
| `screens/contacts/contacts_screen.dart` | 61, 68 | |
| `screens/clawdwallet/agents_screen.dart` | 139, 148 | |

**The three Swap entry points** (the whole reason for this work) are all in
Bucket A and require no change:
- `token_detail_screen.dart:511`
- `staking/staking_detail_screen.dart:156`
- `wallet/wallet_dashboard.dart:631` (`_openSwap`)

### Bucket A′ — Pushes from the shared AppBar widgets
`WalletButton` and `NetworkChip` live in the **shell AppBar**. Their
`Navigator.of(context)` resolves depending on where the branded AppBar ends up
(see §4 AppBar decision):
| File | Line(s) | Pushes |
|------|---------|--------|
| `widgets/wallet_button.dart` | 101 | Account/wallet management |
| `widgets/network_chip.dart` | 60, 74 | Network switch |

- Under **B1** (branded AppBar lives inside each tab's nested navigator) these
  push **in-tab** → bottom nav stays visible (a bonus).
- Under **B3** (branded AppBar stays at shell level) these push on **root** →
  cover the nav, exactly like today.

Either is acceptable; call it out in review.

### Bucket B — Root-targeted, intentional full-screen flows (KEEP on root)
These must remain on the root navigator (full-screen/modal, above the bottom nav
by design). They already target root explicitly — leave them alone.
| File | Line | Mechanism | Why root |
|------|------|-----------|----------|
| `main.dart` | 190 | `rootNavigatorKey.currentState.push` | Deep-link pairing screen |
| `services/wallet_service.dart` + `services/wallet/walletconnect_bridge.dart` | 142 / 20–121 | `rootNavigatorKey` | WalletConnect approval sheets from a service (no tab context) |
| `screens/clawdwallet/pairing_screen.dart` | 47 | `pushReplacement` | Inside the root-pushed pairing flow |

### Bucket C — Pops & dialog results (unaffected)
All `Navigator.pop(...)` / `Navigator.pop(ctx, result)` in dialogs, bottom sheets
and result-returning screens resolve to whatever pushed them, so they keep
working. One to eyeball during testing:
- `settings/security_privacy_screen.dart:146` —
  `Navigator.of(context, rootNavigator: true).pop()` dismisses a **loading
  dialog** (`showDialog` defaults to the root barrier). Correct as-is; verify the
  loading overlay still opens/closes after the refactor.

---

## 4. Target architecture (to-be)

### Core change
Replace the single `IndexedStack` of raw tab bodies with an `IndexedStack` of
**per-tab `Navigator`s**, and keep the `BottomNavigationBar` at the shell level so
it is always visible.

```dart
// One GlobalKey per tab, created once in State.
final _navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

IndexedStack(
  index: _currentIndex,
  children: [
    _TabNavigator(navKey: _navKeys[0], child: HomeScreen(onNavigate: _navigateTo)),
    _TabNavigator(navKey: _navKeys[1], child: const _WalletOrSwapTab()),
    _TabNavigator(navKey: _navKeys[2], child: /* browser, lazy */ ...),
    _TabNavigator(navKey: _navKeys[3], child: const SettingsScreen()),
  ],
)
```

`_TabNavigator` is a thin wrapper around `Navigator` whose **first route** is the
tab root:
```dart
class _TabNavigator extends StatelessWidget {
  final GlobalKey<NavigatorState> navKey;
  final Widget child;
  const _TabNavigator({required this.navKey, required this.child});
  @override
  Widget build(BuildContext context) => Navigator(
    key: navKey,
    onGenerateRoute: (settings) =>
        MaterialPageRoute(builder: (_) => child, settings: settings),
  );
}
```

### Handling `showSwap` for tab 1
Do **not** rebuild/replace the nested navigator's root when `showSwap` flips.
Instead make tab-1's root a small widget that watches the providers and renders
Swap-or-Wallet internally, so the navigator root stays stable:
```dart
class _WalletOrSwapTab extends StatelessWidget {
  const _WalletOrSwapTab();
  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletService>();
    final isUk = context.watch<UkComplianceService>().isUk;
    final showSwap = (wallet.currentAccount?.isMwa ?? false) && !isUk;
    // NOTE: forceSeeker override for the screenshot harness must be threaded
    // through here too (via an InheritedWidget / constructor) — see §7.
    return showSwap
        ? const SwapScreen(initialInputMint: wsolMint)
        : const WalletScreen();
  }
}
```
The bottom-nav item-1 label/icon keeps its own `showSwap` read at shell level
(unchanged).

### AppBar decision — pick ONE

The shell today has **one shared branded AppBar over all tabs**, and pushed
screens carry their **own** AppBar. With nested navigators a pushed route (a full
`Scaffold` with its own AppBar) renders inside the shell body — so if the shell
*also* shows its branded AppBar you get **two stacked AppBars**. Two ways out:

**Option B1 — Branded AppBar moves into each tab root (RECOMMENDED).**
- Remove the shell-level `AppBar`. The shell `Scaffold` keeps only `body` +
  `bottomNavigationBar`.
- Extract a reusable `TibaneAppBar` widget (CatLogo + title + NetworkChip +
  WalletButton) from the current lines 243–263.
- Wrap each tab **root** in a `Scaffold(appBar: const TibaneAppBar(), body: ...)`.
  For the browser (currently a bare `Column`) this means wrapping it in a
  `Scaffold`.
- Pushed routes already bring their own AppBar (with back button) and simply
  replace the tab root when active. **No conditional logic, no observers.**
- Pros: each tab is self-contained; most idiomatic; AppBar pushes (WalletButton /
  NetworkChip) become in-tab (nav stays visible). Cons: touches the 4 tab roots +
  browser to add the Scaffold/AppBar wrapper.

**Option B3 — Branded AppBar stays at shell level, hidden when a nested route is active.**
- Keep the shell AppBar, but add a `NavigatorObserver` per tab that tracks stack
  depth, and set `appBar: activeTabHasPushedRoute ? null : brandedAppBar`.
- Pros: zero changes to tab-root screens & the browser. Cons: needs reliable
  per-tab depth tracking + `setState` on push/pop; AppBar pushes stay on root
  (cover nav, like today); more moving parts to get right.

> Recommendation: **B1.** Slightly more files touched, but no runtime
> state-tracking machinery and a cleaner mental model. This doc's step plan
> assumes B1; §9 notes the B3 delta.

### Android back button — REQUIRED for both options
With nested navigators, the hardware/gesture back goes to the **root** navigator
by default, whose only route is the shell → back would try to exit the app even
when a nested tab has pushed routes. Intercept it:
```dart
// Wrap the shell Scaffold.
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, _) {
    if (didPop) return;
    final nav = _navKeys[_currentIndex].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();                 // pop within the active tab
    } else {
      // At a tab root. Optional: jump to Home tab first, else allow app exit.
      SystemNavigator.pop();     // or set a flag + allow the next back to exit
    }
  },
)
```
Decide the root-level behavior (exit immediately vs. "back returns to Home tab
first"). Document whichever we choose.

### What stays on the root navigator
- Deep-link pairing (`main.dart:190`) and WalletConnect (`walletconnect_bridge`)
  keep using `rootNavigatorKey` — full-screen over the nav, intended.
- Loading dialog pop `rootNavigator: true` (`security_privacy_screen.dart:146`)
  — unchanged.

---

## 5. Files to touch

**Definitely edit:**
- `lib/main.dart` — the whole `TibaneShell` body: nested navigators, PopScope,
  AppBar decision, `_WalletOrSwapTab`, preserve `navigateTo` / `initialIndex` /
  `forceSeeker`.

**Edit only under B1:**
- New `lib/widgets/tibane_app_bar.dart` — extracted branded AppBar.
- `lib/screens/home_screen.dart`, `lib/screens/wallet/wallet_screen.dart`,
  `lib/screens/settings_screen.dart` — wrap root in `Scaffold(appBar: TibaneAppBar())`.
- `lib/screens/browser/dapp_browser_screen.dart` (or `dapp_browser_view.dart`) —
  wrap the `Column` root in a `Scaffold(appBar: TibaneAppBar())`; keep the
  `active` webview-pause wiring intact.
- `lib/screens/swap_screen.dart` — as a **tab** root it needs the branded AppBar;
  as a **pushed** route it must NOT (its pusher supplies the "Swap" AppBar).
  Simplest: leave `SwapScreen` chrome-less and let `_WalletOrSwapTab` wrap it in
  `Scaffold(appBar: TibaneAppBar())`, matching how the pushers wrap it today.

**Do NOT edit (Bucket A auto-migrates):** the 44 push sites listed in §3.

**Optional cleanup (do later, not required):** the three pushed-Swap call sites
(`token_detail_screen.dart:511`, `staking_detail_screen.dart:156`,
`wallet_dashboard.dart:631`) still each hand-roll a `Scaffold(appBar: Text('Swap'))`
wrapper. They keep working unchanged; consider a shared `openSwap(context, ...)`
helper to de-duplicate — tracked separately, out of scope here.

---

## 6. Step-by-step plan

1. **Extract chrome (B1):** create `TibaneAppBar` from `main.dart:243–263`. Verify
   the app still builds with the shell using `const TibaneAppBar()`.
2. **Nested navigators:** add `_navKeys`, `_TabNavigator`, swap the `IndexedStack`
   children to wrapped navigators. Keep `IndexedStack` (all tabs stay alive).
3. **`_WalletOrSwapTab`:** move the `showSwap` body selection into it; thread
   `forceSeeker` for the harness.
4. **AppBar placement (B1):** remove the shell AppBar; wrap each tab root in a
   `Scaffold(appBar: TibaneAppBar())`, including the browser.
5. **Back handling:** add `PopScope` delegating to the active nested navigator;
   choose + document root-level back behavior.
6. **Preserve public API:** keep `navigateTo`, `initialIndex`, `forceSeeker`;
   confirm the screenshot harness path.
7. **Sweep root-nav dependents:** confirm deep link, WalletConnect, and the
   loading-dialog pop still target root correctly.
8. **`flutter analyze`** clean.
9. **Tests** (see §8).
10. **On-device smoke** (see §8) — do NOT commit until the user validates on the
    Seeker (per project rule: leave bug/behavior fixes uncommitted until
    device-validated).

---

## 7. Edge cases & gotchas

- **Screenshot harness / `forceSeeker`:** `_WalletOrSwapTab` must honor
  `forceSeeker` (currently `widget.forceSeeker ?? isMwa`). Thread it via
  constructor or an InheritedWidget from the shell. Confirm
  `TibaneShellState.navigateTo` still drives `_currentIndex`.
- **`initialIndex == 2` (browser first):** keep `_browserVisited` lazy-init and
  the `active: _currentIndex == 2` webview-pause flag. With the browser now a
  nested-navigator root, `active` still keys off `_currentIndex`.
- **Account switch flips `showSwap`:** handled by `_WalletOrSwapTab` watching the
  providers — the tab-1 navigator root stays stable, its content switches. If the
  user had pushed a detail screen inside tab 1 and then switches account, decide
  whether to `popUntil` first-route on tab 1 (recommended, to avoid showing a
  stale wallet screen under a new account). Add if needed.
- **ScaffoldMessenger / SnackBars:** the app-level messenger still serves
  SnackBars from pushed Scaffolds. Sanity-check that Swap SnackBars
  (`swap_screen.dart:307/333/692/1982/2001/2016`) still appear above the bottom
  nav.
- **`WalletButton` / `NetworkChip` push target:** under B1 these become in-tab;
  verify the account switcher and network switch still open and dismiss cleanly.
- **Double back / tab reselect:** optional nicety — tapping the already-active tab
  could `popUntil` its root. Not required; document if added.
- **Deep link while on a deep tab stack:** pairing pushes on root over everything
  — unaffected.

---

## 8. Testing plan

**Existing tests to keep green** (`test/`):
- `widget_test.dart` — pumps `TibaneApp`, expects the "Tibane" title. The branded
  title must still render (under B1 it now comes from `TibaneAppBar` on the tab
  root). **This test will catch an AppBar regression.**
- `startup_gate_test.dart`, `account_switch_route_test.dart`, and the rest are
  logic-level and unaffected, but run the full suite.

**New unit/widget tests to add (per the per-phase-tests project rule):**
1. Bottom nav **stays visible** after opening Swap: pump the shell on an
   MWA/wallet account, tap the Swap entry, assert `BottomNavigationBar` is still
   in the tree and the Swap screen is shown.
2. **Back inside a tab** pops the nested route (not the app): push a detail screen
   in a tab, invoke back, assert we're back at the tab root and still on the same
   tab index.
3. **Tab switch preserves per-tab stack:** push a detail in tab A, switch to tab
   B, switch back to A, assert the pushed detail is still there (IndexedStack +
   nested nav keep state).
4. **`showSwap` flip:** toggle account MWA state, assert tab 1 renders Swap vs
   Wallet and the nav item label flips.

**On-device (Seeker) smoke:**
- Wallet tab → Swap: nav visible, back returns to Wallet tab.
- Token detail → Swap: nav visible; back → token detail → back → tab root.
- Staking detail → Swap: same.
- Browser tab still loads, pauses when backgrounded, resumes on return.
- Deep-link pairing and WalletConnect approval still appear full-screen.
- Account switch flips Swap/Wallet mode correctly.

---

## 9. Decision log

- **D-nav-1:** Approach = **Option B (per-tab nested Navigators)**. Chosen by the
  user over Option A (swap-in-shell, targeted) and Option C (duplicate nav bar,
  stopgap). Rationale: fixes the nav for *all* pushed screens, idiomatic,
  future-proof.
- **D-nav-2 (DECIDED → B1):** AppBar placement = **B1** (branded AppBar in each tab
  root). Implemented by wrapping each tab root centrally in `main.dart`
  (`Scaffold(appBar: TibaneAppBar(), body: …)`) rather than editing the five tab
  screens — same result, less churn, and the browser (a bare `Column`) gets its
  Scaffold from the wrapper. Alternative B3 (shell AppBar + NavigatorObserver)
  rejected: more moving parts.
- **D-nav-3 (DECIDED → pop-else-exit):** back pops the active tab's nested stack
  when it can; at a tab root the app exits (`SystemNavigator.pop()`), matching
  pre-migration behaviour. Encoded in the pure `shellBackAction` helper + tested.
  ("Back to Home tab first" was NOT adopted — kept behaviour predictable.)
- **D-nav-4 (added):** Bottom nav is **hidden while the keyboard is open**
  (`MediaQuery.viewInsets.bottom > 0`) so it doesn't float above the keyboard —
  the bar now lives on the shell Scaffold, outside the tab Navigators.

---

## 10. Risk & rollback

- **Scope:** ~1 tightly-scoped file (`main.dart`) under B3, or `main.dart` + a new
  `TibaneAppBar` widget + 4–5 root wrappers under B1. The 44 push sites are
  untouched, which bounds the blast radius.
- **Highest-risk area:** Android back handling and the AppBar double-render. Both
  are covered by tests #1/#2 and `widget_test.dart`.
- **Rollback:** the change is contained to the shell + (B1) chrome extraction;
  revert those files to restore the single-navigator behavior.
- **Do not commit** until on-device validation on the Seeker (project rule:
  behavior fixes stay uncommitted until the user validates).

---

## 11. Implementation notes (as-built)

**Files changed**
- **`lib/widgets/tibane_app_bar.dart` (new):** `TibaneAppBar`, a
  `PreferredSizeWidget` holding the exact branding lifted from the old shell
  AppBar (CatLogo + "Tibane" + NetworkChip + WalletButton), height 56.
- **`lib/main.dart`:**
  - Imports: dropped `network_chip`/`wallet_button` (now inside `TibaneAppBar`),
    added `tibane_app_bar` and `package:flutter/foundation.dart` (for
    `ValueListenable`).
  - Fields: `_navKeys` (4 `GlobalKey<NavigatorState>`), `_activeTab`
    (`ValueNotifier<int>`); removed `_browserVisited`.
  - `build`: `PopScope` → `Scaffold` (no AppBar) → `IndexedStack` of four
    `_TabNavigator`s, each rooted in `Scaffold(appBar: TibaneAppBar(), body: …)`;
    `bottomNavigationBar` hidden while the keyboard is open, else `_bottomNav()`.
  - New widgets: `_TabNavigator` (per-tab `Navigator` via `onGenerateRoute`),
    `_WalletOrSwapTab` (watches providers for the Swap/Wallet split so the tab-1
    Navigator root stays stable across account switches), `_BrowserTab` (lazy
    build + pause driven by `_activeTab`).
  - Pure helpers (`@visibleForTesting`): `shellBackAction` (D-nav-3) and
    `browserTabState` (lazy-latch + pause), wired into the widgets.
- **`test/navigation_shell_test.dart` (new):** 8 unit tests over the two pure
  helpers — all green.

**Testing deviation from §8:** full-shell widget tests are **not** feasible in
this repo today — pumping `TibaneShell` hangs on the startup gate
(`startupGateReady`) because there's no WalletService/libwallet mock harness.
This is also why the pre-existing `test/widget_test.dart` "App renders" fails
(the first frame shows `_StartupSplash`, whose text is "Tibane Labs", so
`find.text('Tibane')` finds nothing) — **verified failing identically on `HEAD`,
unrelated to this change.** New logic was therefore covered via the extracted
pure helpers. A future WalletService fake would unlock real shell widget tests
(nav-stays-visible, back-pops-tab, per-tab-stack-preserved).

**On-device validation checklist (Seeker) — DO before committing:**
- [ ] Wallet tab → Swap: bottom nav stays visible; back returns to the Wallet tab.
- [ ] Token detail → Swap and Staking detail → Swap: nav visible; back chain intact.
- [ ] Every detail/settings sub-screen now keeps the nav visible (expected side
      effect of Option B) — confirm nothing looks wrong with the persistent bar.
- [ ] Keyboard: opening an input (e.g. Swap amount, Send) hides the nav; closing
      restores it; no nav bar floating above the keyboard.
- [ ] Browser tab: loads on first visit, pauses when you leave, resumes on return;
      cold-start into Browse still works.
- [ ] Account switch flips tab 1 between Swap and Wallet correctly.
- [ ] Deep-link pairing and WalletConnect approval sheets still appear full-screen
      (over the nav), popping back cleanly.
- [ ] Android system back at a tab root exits the app (unchanged).
