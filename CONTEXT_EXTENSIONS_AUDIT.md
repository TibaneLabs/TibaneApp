# `BuildContext` Extensions — Audit

Status: **Implemented (recommended subset).** `lib/utils/context_extensions.dart`
adds `BuildContextX`; a scripted sweep converted the high-value accessors across
45 files — `Theme.of(context).textTheme` → `context.textTheme` (~65),
`ScaffoldMessenger.of(context)` → `context.showSnackBar(...)` / `context.messenger`
(~56), `MediaQuery.of(context).viewInsets.bottom` → `context.keyboardInset` (6),
`FocusScope.of(context).unfocus()` → `context.unfocus()` (5). **`Navigator.of`
(97) was deliberately left as-is** (idiomatic; team call). Analyzer 0 new issues,
311 tests pass. The audit below is the original proposal.

Follows the `context.l10n` pattern introduced with the i18n work. Goal: reduce
the `X.of(context)` boilerplate for the accessors that appear most often, the
same way `AppLocalizations.of(context)` became `context.l10n`.

## TL;DR

There are **~227** `X.of(context)` accessor call sites that could move behind a
`BuildContext` extension. The clear wins are **`Theme.of(context).textTheme`**
(~54) and **`ScaffoldMessenger.of(context)`** (55). `Navigator.of(context)` is
the highest count (97) but the most debatable — it's already idiomatic, so it's
optional. `context.read`/`context.watch` are *already* extensions (from
`provider`) and need no change.

## Counts (lib/, excluding `lib/l10n/gen/`)

| Pattern | Sites | Proposed | Priority | Kind |
|---|---:|---|---|---|
| `Theme.of(context).textTheme.*` | ~54 | `context.textTheme.*` | **High** | dependency |
| `Theme.of(context)` (total) | 64 | `context.theme` / `context.textTheme` / `context.colorScheme` | **High** | dependency |
| `ScaffoldMessenger.of(context)` | 55 | `context.messenger` / `context.showSnackBar(...)` | **High** | lookup |
| `Navigator.of(context)` | 97 | `context.navigator` | Optional | lookup |
| `MediaQuery.of(context).viewInsets.bottom` | 5–6 | `context.keyboardInset` | Medium | dependency |
| `FocusScope.of(context).unfocus()` | 5 | `context.unfocus()` | Low | lookup |
| `context.read<T>()` | 98 | — already an extension (`provider`) | — | — |
| `context.watch<T>()` | 41 | — already an extension (`provider`) | — | — |
| `context.select<…>()` | 1 | — already an extension (`provider`) | — | — |

Usage detail behind the headline numbers:
- **Theme** is used almost entirely for text styles: `titleMedium` (23),
  `titleLarge` (18), `bodyMedium` (5), plus a handful of others. `colorScheme` /
  `primaryColor` / etc. are essentially unused (the app reads colors from the
  static `TibaneColors`, not the `ColorScheme`).
- **ScaffoldMessenger**: 40 inline `…showSnackBar(...)`, 11 captured to a local
  (`final messenger = ScaffoldMessenger.of(context);`) — the capture pattern is
  usually *deliberate*, to grab the messenger before an `await` (see caveat §4).
- **Navigator**: `push` (41), `pop` (36), `pushReplacement` (2), `maybePop` (1),
  `popUntil` (1).
- **MediaQuery**: the only use is `viewInsets.bottom` (keyboard height) — 5–6×.

## 2. Recommended extension

One file, e.g. `lib/utils/context_extensions.dart`:

```dart
import 'package:flutter/material.dart';

extension BuildContextX on BuildContext {
  // --- Theme (registers a dependency: rebuilds when the theme changes) ---
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  // --- MediaQuery: prefer the targeted *Of so we only rebuild on that slice,
  //     not on every MediaQuery change (a small correctness/perf win). ---
  Size get screenSize => MediaQuery.sizeOf(this);
  double get keyboardInset => MediaQuery.viewInsetsOf(this).bottom;

  // --- Ancestor lookups (NO dependency; safe in callbacks / after await) ---
  NavigatorState get navigator => Navigator.of(this);
  ScaffoldMessengerState get messenger => ScaffoldMessenger.of(this);
  void unfocus() => FocusScope.of(this).unfocus();

  /// Inline SnackBar convenience for the common one-liner.
  void showSnackBar(SnackBar snackBar) =>
      ScaffoldMessenger.of(this).showSnackBar(snackBar);
}
```

Before / after:
```dart
Theme.of(context).textTheme.titleMedium        →  context.textTheme.titleMedium
ScaffoldMessenger.of(context).showSnackBar(s)  →  context.showSnackBar(s)
MediaQuery.of(context).viewInsets.bottom       →  context.keyboardInset
FocusScope.of(context).unfocus()               →  context.unfocus()
Navigator.of(context).push(route)              →  context.navigator.push(route)
```

## 3. Not worth doing (or already done)

- **`context.read` / `context.watch` / `context.select`** — already `BuildContext`
  extensions from `provider`. Leave as-is.
- **`context.colorScheme`** — offered above for completeness, but the app draws
  colors from the static `TibaneColors`, so it has ~no call sites. Harmless.
- **A `context.push(route)` / `context.pop()` router-style helper** — tempting
  given 97 Navigator sites, but it bakes in routing opinions (typed results,
  `rootNavigator`, etc.). Prefer the thin `context.navigator` passthrough, or
  leave `Navigator.of` as-is. Not recommended to over-abstract.

## 4. Shared caveat — two different kinds of `.of(context)`

The same rule that applies to `context.l10n` applies here, but split by kind:

- **Dependency-registering** (`Theme.of`, `MediaQuery.*Of`, `Localizations.of`):
  reading them *subscribes* the widget to rebuild when that value changes. Read
  them in `build`; **never cache** the result in a field or global; **not** safe
  in `initState` (no dependency phase yet).
- **Ancestor lookups** (`Navigator.of`, `ScaffoldMessenger.of`, `FocusScope.of`):
  no dependency, no rebuild. These *are* safe in callbacks and after `await`
  (guard with `if (!mounted)` / `if (!context.mounted)` as today). This is why
  the `final messenger = ScaffoldMessenger.of(context)` capture-before-await
  pattern exists — the `context.messenger` getter preserves that (capture it the
  same way; don't inline `context.showSnackBar` across an `await`).

## 5. Suggested rollout

Same playbook as the `context.l10n` sweep (mechanical, so a script beats agents):

1. Add `lib/utils/context_extensions.dart` (above).
2. Scripted `perl`/`sed` sweep, highest-value first:
   - `Theme\.of\(context\)\.textTheme` → `context.textTheme`
   - `Theme\.of\((\w+)\)\.textTheme` → `$1.textTheme` (handles `ctx`, etc.)
   - `MediaQuery\.of\((\w+)\)\.viewInsets\.bottom` → `$1.keyboardInset`
   - `FocusScope\.of\((\w+)\)\.unfocus\(\)` → `$1.unfocus()`
   - `ScaffoldMessenger\.of\((\w+)\)\.showSnackBar` → `$1.showSnackBar` (inline only)
   - (optional) `Navigator\.of\((\w+)\)` → `$1.navigator`
3. Add the import where the extension is used (or a barrel export).
4. `flutter analyze` + `flutter test` — analyzer flags any missed conversion.

**Watch-outs for the sweep:**
- Don't inline-convert `ScaffoldMessenger.of` sites that are captured to a var
  before an `await` — keep those as `final messenger = context.messenger;`.
- `Theme.of(context)` split across lines won't match a single-line regex — do a
  final `grep -rn "\.of(context)"` sweep-check for stragglers.
- The extension getters must be imported wherever used; unlike `l10n.dart` we
  don't need a re-export (these types come from `material.dart`, already imported
  everywhere).

## 6. Effort / impact

| Extension | Sites | Effort | Payoff |
|---|---:|---|---|
| `context.textTheme` (+ `theme`) | ~54 | Low (1 regex) | High — most verbose, most frequent |
| `context.showSnackBar` / `messenger` | 55 | Low–Med (mind the capture pattern) | High |
| `context.keyboardInset` (+ `screenSize`) | ~6 | Low | Medium — also nudges to `viewInsetsOf` (fewer rebuilds) |
| `context.unfocus()` | 5 | Trivial | Low |
| `context.navigator` | 97 | Low (1 regex) | Optional — cosmetic; Navigator.of is already idiomatic |

**Recommendation:** do `textTheme`/`theme`, `showSnackBar`/`messenger`,
`keyboardInset`, and `unfocus()` (a single ~120-site sweep, high readability
payoff). Treat `context.navigator` as optional — decide as a team whether the
cosmetic win is worth touching 97 more sites.
