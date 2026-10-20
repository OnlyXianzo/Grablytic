---
title: Design System and Brand
date: 2026-10-08
tags: [grablytic, architecture, design, theme, brand, typography]
status: complete
---

# Design System and Brand

Token layer, shared components, typography, and logo assets introduced by the `redesign/ui` branch (2026-10-04 → 2026-10-06, commits `9792067` … `4cd06c6`). Repo paths: `lib/core/theme/`, `lib/core/widgets/`, `assets/brand/`, `assets/fonts/`, `DESIGN.md`, `pubspec.yaml`.

> Scope: `redesign/ui` @ `bad0851`, now merged into `main` and shipped in v0.0.5. Line numbers come from that snapshot; re-check them before relying on them.

## Precedence rule (from `DESIGN.md:4-6`)

> "If this file and `app_theme.dart` ever disagree, `app_theme.dart` wins and `DESIGN.md` must be updated."

`DESIGN.md` has already drifted from code in three places (see [[open-questions|open-questions]]).

## Tokens — `lib/core/theme/app_theme.dart` (305 lines)

Four classes, all with private constructors.

| Class | Line | Contents |
|---|---|---|
| `GrablyticColors` | `app_theme.dart:3` | **94 constants**: 47 `light*` (`:7-53`) + 47 `dark*` (`:56-102`). Section comments `// Light tokens — Earth & Ethos` (`:6`), `// Light tokens — Earth & Ethos Dark` (`:55`) |
| `AppTheme` | `app_theme.dart:105` | `static light()` (`:108`), `static dark()` (`:145`), `static _buildTextTheme(ColorScheme)` (`:182`) |
| `GrablyticSpacing` | `app_theme.dart:266` | `xs=4` `sm=8` `md=12` `lg=16` `xl=20` `xxl=24` `xxxl=32` (`:269-275`) |
| `GrablyticRadii` | `app_theme.dart:280` | `sm=8` `md=12` `lg=16` `xl=20` `xxl=24` `sheet=28` (`:283-288`) |
| `GrablyticLogColors` | `app_theme.dart:294` | `info(Brightness)` (`:297`) → dark `0xFF8AB4F8` / light `0xFF0B57D0`; `warning(Brightness)` (`:301`) → dark `0xFFF2C879` / light `0xFF8A4D00` |

Key light tokens: `lightSurface 0xFFfdf9f6`, `lightOnSurface 0xFF1c1b1a`, `lightPrimary 0xFF7d3929`, `lightTertiary 0xFF00584a`, `lightOutlineVariant 0xFFD9c1bc`.
Key dark tokens: `darkSurface 0xFF131313`, `darkOnSurface 0xFFe5e2e1`, `darkPrimary 0xFFffb4a3`, `darkSecondary 0xFFd7c3b0`, `darkOutlineVariant 0xFF54433f`.

**`ThemeData` configures only 4 keys** — `useMaterial3`, `colorScheme`, `scaffoldBackgroundColor`, `textTheme` (`app_theme.dart:137-142`, `:174-179`). No `appBarTheme`/`cardTheme`/`inputDecorationTheme`. **No `ThemeExtension` exists anywhere in `lib/`.**

### Token adoption is uneven (verified by grep)

- `GrablyticColors` is referenced **only inside `app_theme.dart` itself** (50 refs, `:111-177`). Zero uses in `lib/features/`, `lib/providers/`.
- `GrablyticSpacing` / `GrablyticRadii` → only `lib/core/widgets/grablytic_components.dart`.
- `GrablyticLogColors` → only `lib/features/home/widgets/download_log_overlay.dart:108-109`.
- Unused tokens: `GrablyticSpacing.xs/md/xl/xxl/xxxl`, `GrablyticRadii.md/xxl`.
- `lib/features/home/screens/home_screen.dart:782-919` still carries 20+ raw `Color(0xFF…)` literals (e.g. `0xFF8B3A26`, pinned by `test/features/home/home_phase4_test.dart:167,189,198,211`).

## Shared components — `lib/core/widgets/grablytic_components.dart` (388 lines)

File contract (`:4-11`): *"Every component resolves colors, text styles, spacing and radii from the active `Theme` plus `GrablyticSpacing`/`GrablyticRadii` — no hardcoded values… New screens must reuse these instead of inventing one-off equivalents."*

| Component | Line | Purpose |
|---|---|---|
| `SectionLabel` | `:17` | Sentence-case section title (replaces tracked-out uppercase "eyebrows", `:13-16`) |
| `RowCard` | `:40` | Rounded list row — 20px radius, `surfaceContainerLow`, hairline `outlineVariant` @0.3, optional `onTap` |
| `GrablyticProgressBar` | `:82` | Thin linear bar; value clamped 0..1; **deterministic, no animation**; `Semantics` default `'Progress N percent'` |
| `ToggleRow` | `:121` | Icon + title + subtitle + trailing `Switch`; `minHeight: 48`; whole row tappable |
| `GrablyticBottomSheet` | `:196` | Static presenter `show<T>()`; `isScrollControlled`, 28px top radius, 40×4 drag handle, safe-area + `viewInsets.bottom` |
| `SegTabs` | `:248` | Segmented pill tabs; `Semantics(label: 'Options')` |
| `BackHeader` | `:350` | Back header, default label `'Back'`, default action `Navigator.maybePop()`, 48dp min |

**Adoption is minimal:** only 2 production files import it — `lib/features/home/screens/home_screen.dart:9` and `lib/features/settings/screens/about_screen.dart:5`. Actual production usage: `SectionLabel` ×2, `BackHeader` ×1. `RowCard`, `GrablyticProgressBar`, `ToggleRow`, `GrablyticBottomSheet`, `SegTabs` have **no production consumer** — they exist only in `test/core/widgets/grablytic_components_test.dart` (171 lines, 8 tests).

`lib/features/library/screens/library_screen.dart:154` records a product decision: *"Old-style underline tabs (user feedback: revert pill SegTabs)."* — i.e. `SegTabs` was deliberately rejected in Library.

Self-contradiction worth noting: `RowCard` default padding is `GrablyticSpacing.sm + 2` = 10 (`:45`), `_SegTab` uses literal `BorderRadius.circular(12)` (`:322`, `:330`), drag handle literal `circular(2)` (`:232`).

## Typography — five bundled families

Offline-only by design (`app_theme.dart:186-190`): *"Pure-Dart static apply: zero runtime font fetches, zero network beacons."*

| Role | Family | pubspec | Bound at |
|---|---|---|---|
| Display / headline / titleLarge | **BricolageGrotesque** | `pubspec.yaml:83-85`, single face (no weight declared) | `app_theme.dart:183` |
| Body / label / metadata | **Figtree** | `pubspec.yaml:86-88`, single face | `app_theme.dart:184` |
| Mono (machine facts) | **IosevkaCharonMono** | `pubspec.yaml:119-138`, 8 faces (300/400/500/700 × roman/italic) | `text_styles.dart:5` |
| Legacy, unmigrated | InstrumentSans | `pubspec.yaml:89-98`, weights 400/500/600/700 | still hardcoded at `schedule_settings_screen.dart:22,82` and `settings_screen.dart:1656,1663` |
| Declared but unused | `IosevkaCharon` (proportional) | `pubspec.yaml:99-118` | **zero Dart references** |

13 of Material 3's 15 text styles are set; `displayMedium`/`displaySmall` are absent. `headlineSmall` (24 / w600 / Bricolage) exists at `app_theme.dart:208-212`. `test/core/theme/app_theme_test.dart` covers four heading styles and does not assert `headlineSmall`.

`text_styles.dart` (10 lines) adds exactly one thing — the mono extension:

```dart
extension GrablyticTextStyles on TextTheme {
  TextStyle get mono => const TextStyle(
    fontFamily: 'IosevkaCharonMono', fontSize: 13,
    fontWeight: FontWeight.w400, letterSpacing: 0);
}
```

Consumed as `textTheme.mono` in **21 files** (Library, History, Format Picker, Settings, Home, Media Preview).

Licenses shipped alongside: `assets/fonts/OFL-BricolageGrotesque.txt`, `OFL-Figtree.txt`, `OFL-InstrumentSans.txt`.

## Brand assets

`assets/brand/` — 5 masters + `variants/`:

| File | Role |
|---|---|
| `grablytic_logo.png` | **legacy** original |
| `grablytic_logo_light.png` | dark emblem on light background |
| `grablytic_logo_dark.png` | rounded square, light emblem |
| `grablytic_logo_mark.png` | transparent emblem mark |
| `grablytic_logo_circle.png` | **not** a Dart variant; Linux packaging only (`build.yml:277,300`) + README badge |
| `variants/` (18 PNGs) | `{light,dark,mark}` × `{32,48,72,96,144,192}` |

`pubspec.yaml:75-80` declares only **5** assets: the 4 masters + `assets/branding/Grablytic-logo.png`. **The 18 `variants/*` and `grablytic_logo_circle.png` are not declared as Flutter assets** — they cannot be loaded via `Image.asset`.

`assets/branding/Grablytic-logo.png` is declared and named the "canonical asset" in `DESIGN.md:40` but is **never referenced from Dart**.

### `enum LogoVariant` — `lib/core/theme/adaptive_logo.dart:4-34`

`auto` (follows theme brightness, `:5`) · `light` (`:8`) · `dark` (`:11`) · `mark` (`:14`) · `legacy` (`:17`).

`LogoVariant.fromStored(String?)` (`:22-33`) is the single storage entry point (kept deliberately by commit `b397cd0`): `'dark'`→dark, `'light'`→light, `'legacy'`→legacy, **everything else including `null`/`''`/`'system'`/junk → `auto`**.

### `AdaptiveLogo` — `adaptive_logo.dart:38-139`

`size = 96` default (`:40`), optional `borderRadius`, `variant = auto`, `fit = BoxFit.contain`. Reads `Theme.of(context).brightness` at `:61` and switches asset at `:64-82`. Always loads via `Image.asset` with `errorBuilder: (_,_,_) => SizedBox.shrink()` (`:88-94`) — the comment at `:84-87` records why: `File.existsSync` on an asset path is CWD-dependent and diverged between test and device (this was the actual fix in `bad0851`).

Chrome: default radius `size * 0.28` (`:96`), bg `0xFF26201B` dark / `0xFFFAF7F2` light (`:102`), hairline 0.8px (`:104-107`), `BoxShadow` (`:108-113`), `_GrablyticEmblemPainter` at `size * 0.68` (`:121-124`, three paths, red play triangle `0xFFE52E20` at `:157`).

**Conflict:** `AdaptiveLogo` uses a `BoxShadow` (`:108-113`), which contradicts `DESIGN.md:148` and `DESIGN.md:342` ("no `BoxShadow` anywhere" / "no hex literals, no `BoxShadow`").

Call sites: `about_screen.dart:55-62` (size 104, radius 30), `onboarding_screen.dart:119-131` (size 96, 800ms fadeIn), `home_screen.dart:209-212` (size 28, radius 8).

### Settings preference — key `'logoVariant'`

- Allowlist `const _kLogoVariants = {'system','dark','light','legacy'}` (`lib/providers/settings_provider.dart:80`), comment `:77-79` notes it mirrors the enum *"without importing Flutter into the provider layer"*.
- `AppSettings.logoVariant` field `:88`, default `'system'` `:143`, `copyWith` `:197`/`:248`, read+clamp `:323-326`, write `setLogoVariant()` `:486-490`.
- Logged by `lib/core/utils/logging_observers.dart:116`.
- UI: `_SettingLogoSelector` (`lib/features/settings/screens/settings_screen.dart:1782-1872`) in the **Appearance** sub-menu (`:320-336`), title `'App logo'`, subtitle `'Follow theme, or pin Dark, Light, Legacy'`, 4-item dropdown. Semantics: `'App logo, Choose System, Dark, Light, or Legacy'` (`:1798`), `'Logo selection, currently $currentLogo'` (`:1835`).

**Gap:** the enum has 5 values but the dropdown and `_kLogoVariants` allow only 4 — **`LogoVariant.mark` is unreachable** from both UI and storage. `test/features/settings/about_screen_test.dart:20` seeds `'logoVariant': 'mark'`, which the provider clamp at `settings_provider.dart:324-326` silently rewrites to `'system'`.

Tests: `test/core/theme/logo_variant_stored_test.dart`, `test/providers/logo_variant_test.dart`, `test/core/theme/adaptive_logo_test.dart`.

## Android launcher icons

Regenerated from the new mark in `59b7e03` (C9). 20 PNGs across `mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}` × {`ic_launcher`, `ic_launcher_round`, `ic_launcher_foreground`, `ic_launcher_monochrome`}, plus `mipmap-anydpi-v26/ic_launcher.xml` and `ic_launcher_round.xml`.

Adaptive icon has **three** layers (`ic_launcher.xml:2-6`): `<background>`, `<foreground>`, `<monochrome>`. Background pinned to `#121212` (`res/values/colors.xml:3`) by `test/core/launcher_icon_assets_test.dart:31` (commit `cb19d8b` moved the expectation from the old bg to `#121212`).

Foreground sizes are 2.25× the legacy sizes (108/162/216/324/432 vs 48/72/96/144/192) — the Android 108dp-canvas convention — asserted at `launcher_icon_assets_test.dart:6-12,79-82`.

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[dart-providers|dart-providers]]
- [[logging-diagnostics|logging-diagnostics]]
- [[settings-navigation|settings-navigation]]
- [[dev-setup|dev-setup]]
- [[open-questions|open-questions]]
