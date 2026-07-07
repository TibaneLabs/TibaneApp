# Token Metadata Registry — one source of truth for token logos

**Status:** Implemented — pending device validation.
**Goal:** Consistent token icons/metadata everywhere. Kill the "logo shows on the
dashboard but not in swap" class of bug.

## Problem

Token *display* metadata (logo / symbol / name) had **no single source** — each
surface used a different one:

| Surface | Logo source |
|---|---|
| Dashboard rows, swap **From** list | Jupiter (`fetchHoldings.imageUrl`) |
| Swap **To** search results | libwallet token search (`logoUri`) |
| Swap **To** POPULAR | hardcoded `commonTokens` |
| Swap **To** FAVORITES | stored in `FavoritesService` |
| Token detail | Helius `getAsset` |

libwallet's list has logos for far fewer tokens than Jupiter/Helius, so the same
token could show a real logo on the dashboard and a coloured-letter placeholder
in swap.

## Solution

**`lib/services/token_meta_store.dart` — `TokenMetaStore`** (`ChangeNotifier`,
provided at the app root): a single mint→metadata cache backed by Helius DAS
`getAssetBatch` (covers far more SPL tokens than libwallet). Lookups are
**batched** — a burst of icons rendering at once collapses into one RPC call
(~60ms debounce) — and cached for the session (including negatives, so unknown
mints aren't re-requested).

**`lib/widgets/token_icon.dart` — self-resolving `TokenIcon`**: unchanged public
API, but when it has no `imageUrl` and the `mint` is Solana-shaped, it resolves
the logo through `TokenMetaStore` (falling back to the coloured initial until it
lands). So **every** list — dashboard, swap (all sections), send, search,
favorites, token detail — gets the same logo with zero per-call-site plumbing.
Degrades to the fallback if the store isn't in the tree (e.g. isolated tests /
the screenshot harness).

## Notes / follow-ups

- Surfaces that already carry a logo (Jupiter holdings) still pass it directly →
  fast path, no lookup. The store is a **backfill** for missing logos.
- Possible optimization: seed the store from Jupiter holdings so held tokens
  resolve without a Helius round-trip. Not needed for correctness.
- EVM contracts (`0x…`) are skipped (Helius DAS is Solana) → letter fallback.
- Tests: `test/token_meta_store_test.dart` (batching + caching).
