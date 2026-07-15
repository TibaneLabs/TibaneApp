# Multi-language (i18n / l10n) Plan

Status: **Phase 0 implemented** — infrastructure, detection, persistence,
Settings switcher, font fix, and tests are in. String extraction (Phases 1–N)
remains. Audit below unchanged.
Owner: TBD · Created: 2026-07-15

> **Phase 0 done (this branch):** `l10n.yaml` + `intl` + `generate: true`;
> ARB files `lib/l10n/app_{en,fr,ja,pt}.arb`; generated code in `lib/l10n/gen/`;
> `LocaleController` (`lib/services/locale_controller.dart`); `MaterialApp`
> wired with `AppLocalizations.delegate`, `resolveAppLocale` auto-detect, and
> `onGenerateTitle`; **Settings → General → Language** switcher
> (`lib/screens/settings/language_screen.dart`); Noto Sans JP fallback in
> `tibane_theme.dart`; tests in `test/locale_resolution_test.dart`,
> `test/locale_controller_test.dart`, `test/language_switcher_test.dart`.
> **Decision:** Brazilian Portuguese ships as base locale **`pt`** (single
> `app_pt.arb` with Brazilian copy) rather than `pt_BR` — gen_l10n requires a
> base `pt` fallback and we ship only the one Portuguese variant, so every
> Portuguese device (`pt_BR`/`pt_PT`) resolves to it. The endonym still reads
> "Português (Brasil)". Generated `lib/l10n/gen/` is **gitignored** — `flutter
> pub get` regenerates it from the ARBs (verified), so committing it would only
> add churn. Tracked source of truth is `lib/l10n/*.arb` + `l10n.yaml`. (Run
> `flutter pub get` after cloning before a standalone `flutter analyze`.)

Goal: make the Tibane app fully translatable, ship **English, French, Japanese,
and Brazilian Portuguese**, auto-detect the phone's language on first launch
(falling back to English when the device language isn't supported), and add a
**Language** switcher in Settings.

---

## 1. Executive summary

The app is currently **hard-coded to English**. `MaterialApp` declares
`supportedLocales: const [Locale('en')]` and there are **no ARB files, no
`l10n.yaml`, and no `intl`/`AppLocalizations` usage**. All user-facing copy is
inline string literals (`Text('...')`, `labelText: '...'`, `SnackBar`, tooltips,
titles, etc.).

Scale of the work:

- **~90 Dart files** under `lib/` contain user-facing strings.
- **~1,219 user-facing string sites** (Text / label / hint / title / SnackBar /
  tooltip) — see the per-area breakdown in §7.

The work splits cleanly into two parts:

1. **Infrastructure (Phase 0)** — small, self-contained, ships a working
   language switch immediately. Framework wiring + locale detection + locale
   persistence + Settings switcher + font fix + tests. **This is the phase to
   build first.**
2. **String extraction (Phases 1–N)** — the long tail: replace ~1,219 inline
   literals with `AppLocalizations` keys across ~90 files, area by area, each
   phase shipping its own widget tests. This is mechanical but large.

Nothing about the four target languages requires **RTL** layout work (all four
are left-to-right).

> ⚠️ **Critical finding (fonts):** the theme uses Google Fonts **DM Sans**,
> which has **no Japanese/CJK glyphs**. Without a CJK fallback font, Japanese
> copy renders as tofu boxes (□□□). This must be fixed in Phase 0 — see §6.

---

## 2. Current state (audit findings)

| Area | Finding |
|---|---|
| `pubspec.yaml` | `flutter_localizations` (SDK) already a dependency. **No `intl`** declared explicitly, **no `generate: true`** under `flutter:`. |
| `lib/main.dart` | `MaterialApp` sets `localizationsDelegates` for **GlobalMaterial/Widgets/Cupertino** + **PhoneFieldLocalization** only. `supportedLocales: const [Locale('en')]`. No `locale:` set, no `localeResolutionCallback`. Static `title: 'Tibane'`. |
| l10n files | **None.** No `l10n.yaml`, no `lib/l10n/`, no `*.arb`. |
| Strings | 100% inline literals. ~1,219 user-facing sites. Many contain interpolation (`'Detected region: $country'`) → become ICU placeholders. |
| Locale detection | Already done for *compliance* in `lib/services/uk_compliance_service.dart` via `PlatformDispatcher.instance.locales` + `Platform.localeName`. **Reuse this pattern** for language detection. |
| Settings | `lib/screens/settings_screen.dart` → drill-downs in `lib/screens/settings/`. **General** (`general_screen.dart`) is the natural home for a **Language** tile — it's currently near-empty (UK compliance tile + About). |
| Preferences pattern | `lib/services/browser_preferences.dart` is the canonical **`ChangeNotifier` + `SharedPreferences`** provider pattern to mirror for a `LocaleController`. Providers are registered in `MultiProvider` in `main.dart`. |
| Number/keyboard locale | `lib/utils/amount.dart` and `swap_screen.dart` already handle locale-specific **decimal separators**. Crypto amounts are canonical; only *copy* gets translated (see §8). |
| Material widgets | `GlobalMaterialLocalizations` is already wired, so date pickers / default button labels / etc. localize automatically once locales are added to `supportedLocales`. |
| RTL | Not needed (en/fr/ja/pt-BR are all LTR). |

---

## 3. Target languages

| Language | Locale | ARB file | Display name (native) |
|---|---|---|---|
| English (source/template) | `en` | `app_en.arb` | English |
| French | `fr` | `app_fr.arb` | Français |
| Japanese | `ja` | `app_ja.arb` | 日本語 |
| Brazilian Portuguese | `pt` (base; Brazilian copy) | `app_pt.arb` | Português (Brasil) |

Resolution rules (see §5 for the callback):

- Device language **exactly** in the list → use it.
- Device is **`pt`** / `pt_PT` (any Portuguese) → map to **`pt_BR`** (our only
  Portuguese variant).
- Device is any other language (de, es, zh, …) → **fall back to English**.

---

## 4. Chosen approach — Flutter `gen_l10n` (ARB files)

**Recommendation: use Flutter's official `gen_l10n` + ARB.** Rationale:

- `flutter_localizations` is already a dependency — **zero new runtime deps**
  (only the dev-time codegen, which is built into the Flutter SDK).
- Compile-time safety: keys become typed getters (`AppLocalizations.of(context)!.sendButton`),
  so a missing/renamed key is a build error, not a runtime surprise.
- Standard ARB tooling; translators can use any ARB/Crowdin/Localazy pipeline.
- Plays natively with the `GlobalMaterialLocalizations` delegates already wired.

Trade-off vs. alternatives (documented, not chosen):

- **`slang`** — nicer ergonomics (`context.t.foo.bar`, no `!`, hot-reload,
  compile-time), but adds a dependency and a different codegen. Reasonable if the
  team dislikes gen_l10n's boilerplate. **Not recommended** here purely to avoid a
  new dependency and keep the delegate wiring uniform.
- **`easy_localization`** — runtime key lookup (JSON), no compile-time safety.
  **Not recommended** for an app of this size.

### 4.1 Config files to add

`l10n.yaml` (repo root):

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
nullable-getter: false          # AppLocalizations.of(context) is non-null
# untranslated-messages-file: l10n_missing.json   # optional: report gaps
```

`pubspec.yaml` — under `flutter:` add `generate: true`, and add `intl` to deps:

```yaml
dependencies:
  intl: any            # pin to the version flutter_localizations requires
  ...
flutter:
  generate: true       # runs gen_l10n on build / pub get
  uses-material-design: true
```

`AppLocalizations` is generated into `.dart_tool/flutter_gen/...` and imported as
`package:flutter_gen/gen_l10n/app_localizations.dart` (or the configured path).

### 4.2 ARB conventions

- One key per user-facing string. **`lowerCamelCase`** keys grouped by feature
  prefix: `sendAmountLabel`, `swapConfirmButton`, `settingsLanguageTitle`.
- Every key has a `@key` metadata entry in **`app_en.arb`** (the template) with a
  `description` (context for translators) and `placeholders` typing.
- Interpolation → ICU placeholders:
  ```json
  "detectedRegion": "Detected region: {country}",
  "@detectedRegion": {
    "description": "Shown in Settings → General UK-compliance tile",
    "placeholders": { "country": { "type": "String" } }
  }
  ```
- Plurals → ICU `plural`:
  ```json
  "accountsCount": "{count, plural, =0{No accounts} =1{1 account} other{{count} accounts}}"
  ```
- Numbers/dates that must localize → placeholder with `type: int`/`num`/`DateTime`
  and a `format` (`compactCurrency`, `decimalPattern`, …). Crypto balances stay
  canonical (see §8) — do **not** blindly reformat token amounts.

---

## 5. Locale detection, persistence & switching

### 5.1 `LocaleController` (new — `lib/services/locale_controller.dart`)

Mirror `BrowserPreferences` (ChangeNotifier + SharedPreferences). Responsibilities:

- Hold the user's **explicit** choice (`en` / `fr` / `ja` / `pt_BR`) or **null =
  "System default"** (auto-detect).
- Persist under a key like `app_locale` (store the empty string / remove the key
  for "System default").
- Expose `Locale? get locale` — `null` when System default, so `MaterialApp.locale`
  stays null and Flutter runs the resolution callback against device locales.
- `Future<void> setLocale(Locale? l)` → persist + `notifyListeners()`.
- `List<Locale> get supported` = `[en, fr, ja, Locale('pt','BR')]`.

Register it in `main.dart`'s `MultiProvider`, and have `TibaneApp` `watch` it so
`MaterialApp.locale` updates live when the user switches.

### 5.2 `MaterialApp` wiring (in `lib/main.dart`)

```dart
final localeCtl = context.watch<LocaleController>();
return MaterialApp(
  onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appTitle,   // was: title: 'Tibane'
  locale: localeCtl.locale,                    // null = follow device
  localizationsDelegates: const [
    AppLocalizations.delegate,                 // NEW
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    ...PhoneFieldLocalization.delegates,
  ],
  supportedLocales: const [
    Locale('en'), Locale('fr'), Locale('ja'), Locale('pt', 'BR'),
  ],
  localeResolutionCallback: (deviceLocale, supported) {
    if (deviceLocale == null) return const Locale('en');
    // exact language+country match
    for (final l in supported) {
      if (l.languageCode == deviceLocale.languageCode &&
          l.countryCode == deviceLocale.countryCode) return l;
    }
    // any Portuguese → pt_BR
    if (deviceLocale.languageCode == 'pt') return const Locale('pt', 'BR');
    // language-only match (fr_CA → fr, ja_* → ja)
    for (final l in supported) {
      if (l.languageCode == deviceLocale.languageCode) return l;
    }
    return const Locale('en');   // unsupported → English
  },
  ...
);
```

- **First launch, no saved choice:** `locale` is null → the callback picks the
  best device match, English otherwise. This satisfies *"auto-detect, fallback
  English."*
- **User picks a language:** `LocaleController.setLocale(...)` sets `locale`
  explicitly → app rebuilds in that language, persisted across restarts.
- **User picks "System default":** clears the stored value → back to
  auto-detect.

> Note: the resolution logic should be a **pure function** extracted for unit
> testing (mirrors the `startupGateReady` / `shellBackAction` pattern already in
> `main.dart`).

### 5.3 Settings switcher (in `lib/screens/settings/general_screen.dart`)

Add a **Language** `SettingsTile` (icon `Icons.translate` / `Icons.language`)
above the About tile. Tapping opens a simple selection screen or bottom sheet
listing, with a check on the active one:

- **System default** (auto-detect)
- English
- Français
- 日本語
- Português (Brasil)

Each row calls `context.read<LocaleController>().setLocale(...)`. The subtitle on
the General tile / Language tile can show the current selection.

---

## 6. Fonts — Japanese requires a CJK fallback ⚠️

`lib/theme/tibane_theme.dart` builds the text theme from **Google Fonts DM Sans**
(`monoStyle`, base text styles). **DM Sans covers Latin (incl. French/Portuguese
accents) but has NO Japanese glyphs.** Japanese UI would show tofu.

**Implemented (Phase 0):** a **CJK fallback** is wired into the theme via
`cjkFallback` in `tibane_theme.dart` — `GoogleFonts.notoSansJp().fontFamily` is
applied as `fontFamilyFallback` on the base `TextTheme` and on every explicit
font style (app bar, buttons, tabs, snackbar, hints, chips, `monoStyle`,
`serifStyle`). So any DM Sans / Space Mono run falls back to Noto Sans JP for
Japanese codepoints. French & Brazilian Portuguese need **no font work** (DM
Sans covers the accents).

### 6.1 Why fallback, not "Noto Sans JP everywhere"

Using `fontFamilyFallback` is the **recommended** Flutter pattern for
multi-script coverage — not a workaround. We deliberately do **not** make Noto
the primary font, for two independent reasons:

- **Size.** CJK fonts are large (thousands of Kanji + kana): a full Noto Sans JP
  weight is on the order of **several MB per weight**, vs. DM Sans (Latin-only)
  at **tens of KB**. Flutter tree-shakes *icon* fonts (MaterialIcons) but **not**
  text fonts by glyph (any string can be rendered at runtime), so a bundled Noto
  ships whole. Making it primary/bundling-for-everyone means the English/French/
  Portuguese majority — who never render a Japanese glyph — carry MB they never
  use.
- **Brand.** DM Sans is chosen to match tibane.net. Noto's Latin glyphs are
  generic; making it primary would re-typeface ~99% of what most users see and
  lose the brand identity. The fallback keeps DM Sans for Latin and only drops to
  Noto for actual CJK codepoints — the ideal split.

### 6.2 The one open decision: runtime-fetch vs. bundle

| | Binary size | Offline | Notes |
|---|---|---|---|
| **Runtime fetch (current, Phase 0)** | +0 | ❌ needs network on first Japanese render, then disk-cached | `google_fonts` downloads the full weight once; brief flash-of-fallback on first paint |
| **Bundle Noto Sans JP** | +several MB | ✅ works offline immediately | Ship one **variable** font file to cover all weights and keep it to a single asset |

**Recommendation:** keep the **runtime-fetch fallback** for now (zero binary
cost; Japanese users are almost always online at least once). Revisit
**bundling a variable Noto Sans JP** only if offline Japanese on a *fresh
install* becomes a hard requirement for the wallet.

**Do not subset Noto to just the glyphs in our ARB files.** It shrinks the font
a lot, but the app also renders **user-supplied Japanese** — token names,
contact names, transaction memos — which can contain arbitrary Kanji outside the
subset and would tofu. Subsetting is safe for fixed UI copy, unsafe for user
data. If we ever bundle, ship the full (variable) font, not a subset.

**Device check (can't be unit-tested):** the widget tests run with
`GoogleFonts.config.allowRuntimeFetching = false`, so they can't confirm glyphs
actually render. Verify on a real device that Japanese shows real glyphs (not
tofu □□□) — see §11 / QA.

---

## 7. String inventory (per area)

User-facing string sites (Text / label / hint / title / SnackBar / tooltip),
approximate, for **effort sizing and phase batching**:

| Area | ~Sites | Notes |
|---|---:|---|
| `lib/screens/wallet/**` | ~450 | Largest surface: send/receive, tokens, NFTs, backup/restore, import/export, device transfer, unlock, reset password, wallet details. |
| `lib/screens/*.dart` (root) | ~238 | swap, incinerator, fee_sharing, token_detail, token_favorites, home, settings, about. |
| `lib/screens/staking/**` | ~113 | staking_detail (~104 alone), pools, members. |
| `lib/screens/settings/**` | ~88 | security_privacy (~60), help_faq, general, wallets_accounts, connections, browser. |
| `lib/widgets/**` | ~57 | wallet_button, wallet_error_display, tx_success, network chips, token_search, etc. |
| `lib/screens/clawdwallet/**` | ~54 | create_agent_wallet, pairing, agents, activity. |
| `lib/screens/browser/**` | ~41 | approval_sheets (~43 raw), dapp_browser_view. |
| `lib/screens/walletconnect/**` | ~37 | sessions, proposal sheet. |
| `lib/screens/contacts/**` | ~27 | contacts screen. |
| `lib/utils/wallet_error.dart` | ~34 | **Error messages** — see §9 (error-display system). |
| `lib/services/**` | ~few | Mostly non-UI; `libwallet_backend.dart` has strings but many are logs/keys, **not** user copy — audit carefully before translating. |

Highest-density single files (translate-in-one-sitting candidates):
`staking_detail_screen.dart` (104), `swap_screen.dart` (97),
`security_privacy_screen.dart` (60), `incinerator_screen.dart` (55),
`inapp_import_mnemonic_screen.dart` (54), `send_screen.dart` (51),
`fee_sharing_screen.dart` (48), `wallet_details_screen.dart` (45),
`approval_sheets.dart` (43), `cloud_backup_screen.dart` (41).

> The ~1,219 count includes some **non-UI** matches (log strings, map keys,
> asset paths, debug text). Expect the true translatable count to be somewhat
> lower — each extraction pass must judge per-string whether it's user copy.

---

## 8. Policy decisions (resolve before Phase 1)

1. **Crypto amounts / addresses / tickers** stay canonical (not localized number
   formatting). Only *labels and copy* around them translate. `utils/amount.dart`
   already handles locale decimal input — keep that; don't route balances through
   `NumberFormat` unless product wants localized grouping.
2. **Brand / proper nouns** — "Tibane", "Solana", "$ChiefPussy", "WalletConnect",
   "Seeker", token symbols — **do not translate**.
3. **Error strings** — must keep routing through the existing `WalletError.from` /
   `showWalletError` system (see §9). Translate the *presentation* strings, not
   raw libwallet errors.
4. **Legal/compliance copy** (UK compliance tile, ToS) — confirm whether
   translated copy is legally acceptable per locale, or must stay English.
5. **Translation sourcing** — who produces fr/ja/pt-BR? Options: professional
   translators, a localization service (Crowdin/Localazy import ARB), or interim
   machine translation with a `@@ needs-review` marker. **English is the source of
   truth; other ARBs may lag** — gen_l10n falls back to the template for missing
   keys, so partial translations won't crash.
6. **`ja` line breaking / width** — Japanese has no spaces; verify buttons/labels
   don't overflow. Portuguese/French are typically **longer** than English
   (~+15–30%) — verify tight buttons (Send/Swap/Confirm) don't clip.

---

## 9. Interactions with existing systems

- **Error display** (memory: never show raw libwallet/`$e` errors). Translated
  strings must flow through `WalletError.from` → `showWalletError` /
  `walletErrorCard`. When extracting `utils/wallet_error.dart`, translate the
  human-readable mapping, keep the developer `debugPrint` (memory: log user
  errors) in English/raw.
- **PhoneFieldLocalization** already localizes the phone field's country picker —
  adding fr/ja/pt to `supportedLocales` makes it follow the app locale for free.
- **UK compliance** reads device locale independently — unaffected, but the
  detected-region *copy* in `general_screen.dart` gets translated.
- **Providers** — `LocaleController` joins the `MultiProvider` list in `main.dart`
  alongside `WalletService`, `BalancesStore`, etc.

---

## 10. Phased work plan

Each phase ships its **own unit/widget tests** (repo rule: tests per phase) and is
**not committed until explicitly approved** (repo rule).

### Phase 0 — Infrastructure (ships a working switch) 🚦
1. Add `intl` dep + `generate: true`; add `l10n.yaml`.
2. Create `lib/l10n/app_en.arb` (template) + `app_fr.arb`, `app_ja.arb`,
   `app_pt_BR.arb` with a **starter key set**: app title, the Settings→Language
   UI strings, and ~10 common strings (Cancel/Confirm/Save/Close/Send/Receive/…).
3. Wire `AppLocalizations.delegate`, expand `supportedLocales`, add
   `localeResolutionCallback` (pure fn, unit-tested), `onGenerateTitle`.
4. Add `LocaleController` (persistence) + register provider; `MaterialApp.locale`
   follows it.
5. Add **Language** switcher in `general_screen.dart` (+ selection UI).
6. **Font fix:** add Noto Sans JP (or bundle) fallback in `tibane_theme.dart`.
7. Tests: locale-resolution pure-fn (device→resolved), `LocaleController`
   persistence, widget test pumping the switcher and asserting `Localizations.localeOf`.
   **Verify Japanese renders (no tofu) on device/emulator.**

> After Phase 0 the app **switches languages end-to-end** even though most screens
> are still English — because untranslated keys fall back to the template.

### Phases 1–N — String extraction (batch by area, biggest first)

> **P2–P9 ✅ DONE.** All remaining screens localized via a 12-way parallel
> subagent fan-out (each agent owned disjoint `.dart` files and emitted a JSON
> key fragment; a merge script folded ~905 new keys into the 4 ARBs with
> `@placeholder` metadata). **986 keys/locale**, en/fr/ja/pt parity enforced by
> `l10n_arb_parity_test.dart`; smoke coverage in `all_screens_localization_test.dart`.
> Full suite green (311 tests), analyzer 0 new issues.
>
> **Follow-ups / residuals** (not blockers):
> - **Native translation review** — fr/ja/pt were machine-generated. Agents
>   flagged specific ja kanji (some typos already fixed post-merge) and
>   crypto-term choices (share/jeton/token, swap/échange) for a native pass.
> - A few strings intentionally left English: `create_agent_wallet` hint that
>   embeds the `clawdwallet init` CLI command; the `collectManagementKeys`
>   title/purpose in `security_privacy` (rotate device share); a couple of
>   `_formatTime` "x min ago" helpers with no `BuildContext`.
> - **`utils/wallet_error.dart` NOT localized** — the `WalletError` message
>   mapping is architectural (needs a key+args carried to display time); left
>   English on purpose. Its own display widget (`wallet_error_display.dart`) IS
>   localized. This is the natural next task.
> - Lessons logged: agents that also loaded the (large) `app_en.arb` risked
>   context overflow (swap agent died once → split + git-diff recovery for
>   incinerator); a smart-quote substitution slipped into 3 files (fixed);
>   int-typed placeholders needed explicit ARB `type: int` overrides.

Original batching (each is an independent PR with widget tests):

- **P1 ✅ DONE** — `screens/wallet/**` send/receive/tokens (highest traffic):
  `send_screen.dart`, `receive_screen.dart`, `tokens_screen.dart`. Tests:
  `l10n_arb_parity_test.dart`, `send_localization_test.dart`,
  `receive_tokens_localization_test.dart`. Also fixed the `ja` phone-delegate
  warning via `FallbackLocalizationsDelegate` (`fallback_localizations_delegate_test.dart`).
  - ✅ **`send_screen.dart` done** — ~34 keys added across all 4 ARBs (7 reusable
    `labelFrom/labelTo/labelNetwork/labelTransaction/backToHome/viewOnExplorer[Named]`
    + send-specific). Tests: `test/l10n_arb_parity_test.dart` (key-parity guard,
    reused by all later phases) + `test/send_localization_test.dart`.
    **Conventions established here** (follow for the rest):
    - Keys are `lowerCamelCase`, screen-prefixed (`send*`); genuinely shared
      labels get a `label*` / neutral name and are reused across screens.
    - Reuse existing `actionCancel` / `actionConfirm` etc. for generic buttons.
    - Interpolation → ICU placeholders (`sendTitle(symbol)`,
      `sendBalanceLabel(balance, symbol)`); backend/dynamic text (libwallet
      warnings, `WalletError.from(e).message`, `sim.revertReason`) is **not**
      translated — only the surrounding copy.
    - Number formatters (`formatSendUsd`, `_fmtBalance`, …), tickers, addresses,
      and proper nouns ("Solana") stay canonical.
    - `copyWithToast(context, value, label)` in `widgets/tx_success.dart`
      concatenates `"$label copied"` internally and is shared with swap, so its
      two toast labels ("Address", "Transaction ID") were **left English** and
      are deferred to **P8** (widgets) to avoid mixed-language toasts. Helpers
      that render a `label` arg directly (`txReceiptCard`, `txExplorerLink`,
      `txBackToHomeButton`) are localized by passing a translated arg.
  - ✅ **`receive_screen.dart` + `tokens_screen.dart` done** — added generic
    reusable keys (`actionAdd/actionRemove/actionRefresh`,
    `labelAddress/labelName/labelSymbol/labelType/labelDecimals/labelTotalSupply`,
    `addressCopied`) + `receive*` / `tokens*` keys. **Gotcha logged:** a lone
    apostrophe inside an ICU message that *also* has a placeholder is treated as
    ICU quoting and eats the apostrophe — so `tokensRemoveBody` (fr) was worded
    to avoid `l'adresse` ("son adresse"). Apostrophes in placeholder-free
    messages (e.g. `tokensAddDialogBody` fr) are fine.
- **P2** `screens/wallet/**` backup / restore / import / export / device-transfer / unlock / reset.
- **P3** `swap_screen.dart` + `incinerator_screen.dart` + `fee_sharing_screen.dart`.
- **P4** `screens/staking/**`.
- **P5** `screens/settings/**` + `settings_screen.dart` + `about_screen.dart`.
- **P6** `screens/clawdwallet/**` + `screens/walletconnect/**` + `screens/browser/**`.
- **P7** `screens/contacts/**` + `home_screen.dart` + `token_detail`/`favorites`.
- **P8** `widgets/**` + `utils/wallet_error.dart` (error copy).
- **P9** Straggler sweep + services audit (translate only true UI copy).

Per-phase mechanics:
1. Replace literals with `AppLocalizations.of(context).<key>`; add keys to
   **all four** ARBs (en real, fr/ja/pt-BR translated or marked for review).
2. Add/adjust widget tests wrapping the screen in `MaterialApp` with each locale.
3. `flutter analyze` + `flutter test` clean.

### Final — Hardening
- **ARB key-parity test** (dev test): assert every non-template ARB has the same
  key set as `app_en.arb` (catches missing/typo'd translations). Optionally fail
  CI on gaps via `untranslated-messages-file`.
- Manual QA pass per locale (fr, ja, pt-BR): overflow, tofu, truncation,
  date/number formatting, phone field, Material dialogs.
- Optional: a lint/grep gate to catch **new** hard-coded `Text('...')` in PRs.

---

## 11. Testing checklist (per repo rule: tests per phase)

- `test/locale_resolution_test.dart` — pure resolver: `en_US→en`, `fr_CA→fr`,
  `ja_JP→ja`, `pt_PT→pt_BR`, `pt_BR→pt_BR`, `de_DE→en`, `null→en`.
- `test/locale_controller_test.dart` — set/persist/restore; "System default"
  clears; notifies listeners.
- Widget test — pump `general_screen` language switcher, tap a language, assert
  `Localizations.localeOf(context)` + persisted value.
- Per-extraction-phase widget tests — screen renders under each of the 4 locales
  without throwing / with expected translated text.
- Final ARB-parity test — all ARBs share `app_en.arb`'s keys.

---

## 12. Risks & open questions

- **Fonts / Japanese tofu** — addressed in Phase 0 via a runtime-fetched Noto
  Sans JP fallback. Open decision (bundle a variable font for offline vs. keep
  runtime-fetch) and the "don't subset" caveat are documented in **§6.2**;
  current recommendation is runtime-fetch until offline-first-launch Japanese is
  a hard requirement.
- **Scale** — ~1,219 sites is a multi-PR effort; Phase 0 delivers value early,
  the rest is incremental and low-risk (fallback protects untranslated keys).
- **Translation quality/sourcing** — need real fr/ja/pt-BR translations; decide
  vendor vs. machine-interim. Legal copy may need sign-off.
- **Layout overflow** — French/Portuguese longer, Japanese wraps differently;
  QA tight buttons.
- **`pt` vs `pt_BR`** — only Brazilian variant shipped; `pt_PT` users get pt-BR
  (documented, acceptable).
- **Services strings** — `libwallet_backend.dart` etc. mix logs/keys with copy;
  audit each string before translating.

---

## 13. Concrete next step

Build **Phase 0** end-to-end (infra + detection + persistence + Settings switcher
+ font fix + tests). It's small, isolated, reversible, and makes the language
switch demonstrable immediately — after which string extraction (Phases 1–N) is
mechanical and can proceed area-by-area at whatever pace translations arrive.
