# Grablytic Design System

> **Version:** 1.0 · **Status:** Canonical
> **Source of truth for tokens:** `lib/core/theme/app_theme.dart` (`GrablyticColors`, `AppTheme`)
> This document describes intent and usage. If this file and `app_theme.dart`
> ever disagree, `app_theme.dart` wins and this file must be updated.

Grablytic looks like a **curated bazaar**: warm paper, deep ink text, one
confident terracotta voice for the primary value and the primary action,
and a quiet sage voice reserved for verified / saved / healthy states.
Depth comes from cream-on-cream tonal shifts and paper gutters — never
from drop shadows.

---

## 1. Principles

1. **Warm before technical.** The app handles binaries, threads and logs,
   but it speaks like a human shelf of hand-picked items — not a console.
2. **One loud thing per card.** Every card has a single oversized terracotta
   value (size, quality, progress, count). Everything else stays quiet.
3. **Provenance on everything.** Every item carries a tracked-out uppercase
   eyebrow that says where it is from and what it is
   (`1080P · YOUTUBE`, `PLAYLIST · 24 ITEMS`, `PRESET · PODCAST`).
4. **Tonal, never shadowed.** Surfaces are borderless tonal tiles separated
   by paper gutters. Elevation is a lighter cream, not a shadow.
5. **Touch-first, TalkBack-complete.** 48×48 targets, semantic labels on
   every icon-button, full screen-reader flow.

---

## 2. Brand and logo

The Grablytic mark is a white geometric play-mark — an angular play
triangle folded into a hexagonal `G` form — set on a terracotta paper
field, with a soft-serif `Grablytic` wordmark below it in paper white.

- **Canonical asset (repo):** `assets/branding/Grablytic-logo.png`
- **TODO (launcher/small-size pass):** the new play-mark artwork
  (`Grablytic-logo-square.jpg` source, 4032×4200) ships full-bleed with a
  photographic vignette — legible large, but verify 48 dp launcher and
  16 dp favicon rendering on-device; flatten to a solid Terracotta Deep
  field if the vignette muddies small sizes.
- **Field:** Terracotta Deep (see §3) with visible paper grain. Never
  flat-red, never gradient.
- **Mark / wordmark:** Paper White `#FFFFFF` on terracotta; Espresso
  `#1C1B1A` on paper. Never terracotta-on-terracotta.
- **Clearspace:** height of the mark's top edge on all four sides. Nothing enters it.
- **Minimum sizes:** 32 dp app bar / splash icon, 120 dp hero, 16 dp favicon
  floor (mark only, no wordmark below 48 dp).
- **Do:** place on paper cream, terracotta deep, or espresso. Use the full
  lockup on onboarding, About and splash.
- **Do not:** add shadows, rotate, recolor the `T`, set the wordmark in
  Instrument Sans, or place on busy thumbnails without a paper scrim.

---

## 3. Color

### 3.1 Roles

| Role | Light | Dark | Used for |
|---|---|---|---|
| Paper base | `#FDF9F6` `lightSurface` | `#131313` `darkSurface` | Scaffold, app background |
| Paper tile lowest (brightest) | `#FFFFFF` `lightSurfaceContainerLowest` | `#0E0E0E` `darkSurfaceContainerLowest` | Cards, sheets, dialogs |
| Paper tile low | `#F7F3F0` `lightSurfaceContainerLow` | `#1C1B1B` `darkSurfaceContainerLow` | Search field, input wells |
| Paper tile | `#F1EDEA` `lightSurfaceContainer` | `#201F1F` `darkSurfaceContainer` | Thumbnail wells, info tiles |
| Paper tile high | `#EBE7E4` `lightSurfaceContainerHigh` | `#2A2A2A` `darkSurfaceContainerHigh` | Pressed / hover, segmented wells |
| Paper tile highest | `#E5E2DF` `lightSurfaceContainerHighest` | `#353534` `darkSurfaceContainerHighest` | Progress track, dividers |
| Espresso ink | `#1C1B1A` `lightOnSurface` | `#E5E2E1` `darkOnSurface` | Titles, body |
| Muted ink | `#54433F` `lightOnSurfaceVariant` | `#D9C1BC` `darkOnSurfaceVariant` | Secondary text, metadata |
| Hairline | `#D9C1BC` `lightOutlineVariant` | `#54433F` `darkOutlineVariant` | Borders at 20–40% alpha |
| Faint ink | `#87736E` `lightOutline` | `#A28C87` `darkOutline` | Icons, hints |
| **Terracotta (primary)** | `#7D3929` `lightPrimary` | `#FFB4A3` `darkPrimary` | Primary value, primary button, active tick |
| Terracotta container | `#9B503E` `lightPrimaryContainer` | `#9B503E` `darkPrimaryContainer` | Active pill, nav indicator |
| On terracotta | `#FFFFFF` `lightOnPrimary` | `#581D0F` `darkOnPrimary` | Text on primary button |
| Terracotta wash | `#FFDAD2` `lightPrimaryFixed` | `#FFDAD2` `darkPrimaryFixed` | Stage chips, highlights |
| **Sage (verified / healthy)** | `#00584A` `lightTertiary` | `#B7CCB9` `darkTertiary` | Verified tick, saved heart, engine-healthy |
| Sage container | `#007361` `lightTertiaryContainer` | `#576A5B` `darkTertiaryContainer` | Healthy banner fill |
| On sage | `#FFFFFF` `lightOnTertiary` | `#233427` `darkOnTertiary` | Text on sage banner |
| Danger | `#BA1A1A` `lightError` | `#FFB4AB` `darkError` | Errors, expired, destructive |
| Danger wash | `#FFDAD6` `lightErrorContainer` | `#93000A` `darkErrorContainer` | Error card fill |

Full token list (fixed shades, secondary surfaces, inverse pairings) lives
in `GrablyticColors` — consume via `Theme.of(context).colorScheme`, never
as hex literals. New code with a hex literal fails review.

### 3.2 Distribution

- **60 / 30 / 10:** ~60% paper base, ~30% tonal tiles, ~10% ink + accent.
- Terracotta appears **once as value + once as action** per viewport
  (e.g. large size + `Download` button). Never for body text, never for
  decoration.
- Sage appears only for: verified source tick, saved confirmation,
  engine-healthy / download-complete states. Never as a second primary.
- Danger appears only for: failed / expired / destructive. Expired resume
  candidates use danger wash + `timer_off` icon, never plain grey.

---

## 4. Typography

- **Product face:** Instrument Sans (`GoogleFonts.instrumentSansTextTheme`).
- **Technical face:** Iosevka Charon Mono (`textTheme.mono`) — bytes,
  speed, ETA, URLs, log lines, template strings. Never for prose.
- **Brand face:** the logo wordmark serif is reserved for the logo lockup
  and the splash hero. Product UI never sets headlines in that serif.

| Style | Spec | Use |
|---|---|---|
| Display | 48 / Light / −2% | Splash hero only |
| Headline | 32 / Regular, 28 / Regular | Detail title (`1970s…` scale), empty-state title |
| Title | 24 / Medium, 18 / Medium | Screen titles, dialog titles, `Your Library` |
| Body large | 16 / Regular / 1.5 | Hero strapline (italic, muted), dialog prose |
| Body medium | 14 / Regular / 1.5 | Card titles (600 weight, 2-line max), list rows |
| Body small | 13 / Regular | Helper text under inputs |
| Label large | 14 / Medium | Buttons |
| Label small | 12 / Regular | Metadata, timestamps |
| **Eyebrow** | 11 / 600 / uppercase / +1.5 tracking / terracotta or muted ink | Provenance line on every card and section (`INTERRUPTED DOWNLOADS`, `FORMAT · YOUTUBE`) |
| **Primary value** | 20–28 / 700 / terracotta | The loudest thing on the card: size, quality, `%`, count |
| Mono | 13 / Regular (11 for dense rows) | `128 MB / 1.2 GB`, `4.1 MB/s · ETA 02:14`, `99 % downloading` |

Eyebrows are always one line, truncated with ellipsis. Titles are max
two lines. Never center-align card text except the empty state and hero.

---

## 5. Shape, spacing, elevation

- **Radii:** 8 (wells, badges, progress), 12 (inputs, cards), 16 (dialogs,
  hero tile, viewer), 24 (active nav pill). Filter chips and avatar stacks
  are full pills / circles.
- **Gutters:** 8 dp between masonry tiles, 12–16 dp card padding, 20 dp
  screen edge, 24–32 dp section gaps. The gutter is always visible paper —
  tiles never touch.
- **Borders:** 1 dp `outlineVariant` at 20–40% alpha on cards and inputs.
  Error cards use danger at 40% + danger wash at ~12% fill.
- **Elevation:** no `BoxShadow` anywhere. Resting tile = tile-low on base;
  pressed = tile-high; emphasis = brightest tile + hairline. Dark mode uses
  the same steps on the dark ramp.
- **Progress:** 4 dp rounded bar, track = tile-highest, fill = terracotta
  container. Determinate values cap display at 99% until the terminal
  `finished` event (by design — reserves the completion beat).

---

## 6. Components

### 6.1 App bar + search

Paper base, no divider. Title is 18 Medium. The search well is a 12-dp
tile-low field with a leading search icon, hint in faint ink
(`Enter link…`, `Search library…`), and a trailing clear `×` when text is
present. Home pairs the field with two 48×48 square actions (batch import,
submit) — submit is terracotta container with paper icon.

### 6.2 Category / preset chips

Horizontally scrolling pill row under search. Resting chip: tile-high fill,
muted-ink label. Selected chip: espresso fill (light) / terracotta fill
(dark) with paper label. Exactly one selected at a time.

### 6.3 Featured banner

Full-width 16-dp image tile with a paper scrim. Content, top to bottom:
eyebrow (`FEATURED COLLECTION`, paper, 60% opacity), 24 Medium headline
(paper white, two lines), terracotta pill action (`EXPLORE`, `VIEW`). Used
on Home for the current highlight (e.g. new engine capability, featured
preset pack). One per screen, never stacked.

### 6.4 Masonry grid cards

Two-column staggered grid, 8-dp paper gutters, borderless tonal tiles:

- Thumbnail well (tile base, 8-dp radius) with optional top-right circular
  save heart (paper fill, sage icon when saved).
- Overlapping circular source avatar at the well's bottom-left edge.
- Eyebrow (`VINTAGE · BERLIN` pattern → `4K · YOUTUBE`, `MP3 · PODCAST`).
- Title, 14 / 600, two-line max.
- Primary value, 20 / 700 terracotta, one line (`$185` pattern → `1.2 GB`,
  `2160P`, `99%`).
- Completed state appends a sage check; failed state appends a danger
  message line + recovery affordance.

### 6.5 Detail header (carousel)

Edge-to-edge media with floating circular back / share / save actions
(paper fill). Below: dot indicator, eyebrow, 28 headline title, terracotta
primary value row with a muted qualifier (`Local Pickup Only` pattern →
`Wi-Fi only`, `Subs embedded`, `SponsorBlock on`). Never put the primary
value in ink — it must be the loudest element.

### 6.6 Info tiles

Paired tonal tiles (`CONDITION` / `DIMENSIONS` pattern → `QUALITY` /
`SIZE`, `CODEC` / `CONTAINER`, `AUDIO` / `SUBTITLES`). Each tile: 11-sp
eyebrow + 14 Medium value, tile fill, 12-dp radius, no border emphasis.

### 6.7 Source strip

Brightest-tile row: circular avatar, name (600), subline
(`4.9 · 212 sales` pattern → `YOUTUBE · 1080P CAP`, `CHANNEL · 24 ITEMS`)
with a sage verified tick when the source is allowlisted/healthy, and a
trailing chevron opening the source profile.

### 6.8 Buttons

- **Primary:** terracotta fill, paper label, 12-dp radius, 48+ height
  (`Make Offer` pattern → `Download`, `Resume`, `Start anyway`).
- **Secondary:** paper-wash fill, ink label (`Contact` pattern → `Preview`,
  `Formats`, `Wait`).
- **Destructive / retry:** outlined danger or terracotta-outline.
- Dialogs keep actions right-aligned: quiet `Dismiss`/`Wait` text button +
  one primary.

### 6.9 Filter row + result count

Horizontally scrolling outlined pills (`Price · Distance · Condition`
pattern → `Quality · Source · Status · Type`) over an 11-sp tracked count
line (`128 RESULTS FOUND` pattern → `24 ITEMS · 1.2 GB`). Active filter
pill is terracotta-wash with terracotta label.

### 6.10 Status pills and badges

Offer-status pill pattern maps to download state: `downloading`
(terracotta wash + hourglass), `post-processing` (terracotta wash),
`complete` (sage wash + check), `error` (danger wash), `expired`
(danger wash + timer_off). Price-drop badge pattern maps to
quality/size badges (`4K`, `AV1`, `MPS`, `ARCHIVED`) — 4-dp tile-high chip,
10-sp mono 700.

### 6.11 Bottom navigation

Three destinations: **Download · Library · Settings**. Paper fill with a
top hairline. Active destination is a 24-dp terracotta-container pill with
paper icon + label; inactive is a muted icon over a muted label. A 2-dp
terracotta underline tick sits under the active pill on narrow screens.
Wide screens (>600 dp) use `NavigationRail` with the same active-pill
semantics. Minimum target 48×48, every item semantically labelled.

### 6.12 Cards, banners, dialogs

- **Status banner:** full-width 8-dp sage-container row (icon + labelSmall)
  for healthy/engine notes. Errors use the danger-wash card with bold
  titleSmall + prose + outlined danger action (`Open Log & Report`).
- **Recovery card:** brightest tile + danger hairline when failed, with
  one-tap fix row (retry / cookies / proxy / pick format) — never a raw
  string dump.
- **Dialogs/sheets:** brightest tile, 16-dp radius, titleMedium + bodyMedium,
  48-dp actions. Bottom sheets use the same fills at full-bleed with a
  4-dp grabber in tile-highest.

---

## 7. Screens

Seven connected patterns form the complete flow. Grablytic's
implementation screens bind to them as noted:

1. **Home feed** — search, chips, featured banner, recent-items masonry.
   → `HomeScreen` (URL input, resume scan, `Your Library` cards,
   bootstrap/error states), `OnboardingScreen`.
2. **Detail** — carousel, eyebrow + title + terracotta value, info tiles,
   source strip, primary/secondary actions.
   → `MediaPreviewScreen`, `FormatPickerScreen` (stream list, codec /
   container choice, muxed badges).
3. **Search results** — query field with clear, filter row, result count,
   masonry grid with avatars and primary values.
   → `LibraryScreen` (grid/list toggle, search + filters),
   `DownloadHistoryScreen`, `PlaylistDetailsScreen`.
4. **Source profile** — avatar header, rating/health line, active-items
   list. → per-site extraction profiles (`ProfileEditorScreen`), observed
   sources (`ObservedSourcesScreen`), cookie identity (`CookieWebViewScreen`).
5. **Activity** — list with status pills, tap-to-expand rows, export.
   → `LogViewerScreen` (live color-coded stream, level/tag/search/source
   filters), diagnostics + engine status cards, batch progress
   (`BatchDownloadScreen`).
6. **New entry flow** — paste/import → configure → confirm. Single primary
   action per step, schedule-gate dialog when outside the download window.
   → `BatchImportDialog`, preset application (`PresetsScreen`,
   `CommandTemplatesScreen`), schedule confirmation (`ScheduleSettingsScreen`).
7. **Saved** — saved grid with drop/change badges.
   → `LibraryScreen` saved filter, `DownloadHistoryScreen`,
   `PresetsScreen` (7 built-in + custom).

Supporting screens reuse the same kit: `SettingsScreen` hierarchy
(quality, network, engine packages, subtitles, SponsorBlock, schedule,
archive, auth, updates), `SubtitleSettingsScreen`,
`SponsorBlockSettingsScreen`, `CookiesScreen`, `AboutScreen`.

---

## 8. Motion

- `flutter_animate`: hero `fadeIn` 400 ms + `slideY` 0.2 easeOutCubic;
  inputs trail at +200 ms. Never animate the terracotta value itself.
- Tab changes: 300 ms easeInOut pager animation; swipe and tap land on the
  same destination exactly once (fly-through pages ignored).
- Progress and log streams update in place — no list jumps, no shimmer on
  determinate rows. Shimmer/Lottie/Rive are reserved for indeterminate
  bootstrap and empty-state illustration.

---

## 9. Accessibility and dark mode

- WCAG 2.2 AA: contrast pairs from §3 only, 48×48 targets, visible focus,
  TalkBack/VoiceOver labels on every icon-button, card, nav item and status
  pill. Terracotta-on-paper and paper-on-terracotta pairs are the only
  approved accent text combinations.
- Dark mode is the dark ramp in §3, not an inverted light theme:
  terracotta lightens to `#FFB4A3` for text values while containers stay
  deep; sage lightens for ticks; surfaces step down the dark tile ladder.
- Mono values (`13 sp`, `11 sp` dense) never drop below 11 sp and never
  carry prose meaning alone — always paired with an icon or label.

---

## 10. Implementation binding

- Tokens: `GrablyticColors` in `lib/core/theme/app_theme.dart`;
  schemes: `AppTheme.light()` / `AppTheme.dark()` (`useMaterial3: true`,
  scaffold = surface, `instrumentSansTextTheme`).
- Mono: `GrablyticTextStyles.mono` (`lib/core/theme/text_styles.dart`).
- Shell: `AppShell` — `PageView` + bottom pill nav (<600 dp) /
  `NavigationRail` (wide). Providers stay Riverpod; shared UI state never
  in `setState`.
- Rules for new code: no hex literals, no `BoxShadow`, no primary-colored
  body text, no new radius outside §5, every image card gets eyebrow +
  title + terracotta value, every icon-button gets `Semantics(label:)`.
- Verify: `flutter analyze` zero-error, `flutter test`, relevant `pytest`
  for engine-touched flows.
