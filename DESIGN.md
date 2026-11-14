# Design: the Taproom style

Retappd's screens use one design language, "Taproom": warm, calm and tactile, like a
craft-beer bar's menu board rather than stock iOS grouped lists. The check-in screen
(`Retappd/Features/CheckIn/CheckInSheet.swift`) is the reference implementation. When you
redesign a screen, open it next to that one and make them feel like the same app.

Everything below is available as shared code in `Retappd/Design/Taproom.swift`. Use those
pieces rather than re-creating them, and add new shared pieces there rather than one-offs.

## Principles

- **Content on a warm page, not in grouped lists.** Avoid `Form` and inset-grouped `List`
  for screens people mainly look at or edit. Lay content out directly on
  `Taproom.background`, using cards only where something needs a boundary (a text field, a
  photo, a tappable row).
- **One hero per screen.** Each screen has one big element you interact with directly, and
  it sets the mood. On check-in, that's the glass you drag to rate, with the score in heavy
  64pt type beside it. Find the equivalent elsewhere (a beer's label and rating, a venue's
  name and map, a profile's avatar and stats).
- **Few, warm colours.** Ink on a warm off-white, with amber as the only accent. Colour
  means "selected" or "this is the beer", never decoration.
- **Physical, small motion.** Springs, haptic ticks and bubbles that answer what your
  finger does. Nothing moves on its own for long, and everything decorative is turned off
  under Reduce Motion.
- **Thumb-friendly.** Put interactive heroes on the right-hand side for right-handed reach,
  keep the main action in a bar pinned at the bottom, and keep every touch target at least
  44pt tall.

## Colour

All colours come from `Taproom` and have light and dark values. Never use raw `.orange`,
`.secondary` or system grouped backgrounds on a Taproom screen.

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#FBF8F3` | `#17130E` | Screen background, nav bar, bottom bar |
| `card` | `#FFFFFF` | `#241E17` | Cards, fields, unselected chips |
| `border` | `#E7DDCE` | `#3A3128` | 1pt borders on cards, fields, chips |
| `ink` | `#2B2118` | `#F4ECDF` | Primary text; primary button fill |
| `muted` | `#6F6252` | `#B0A38F` | Secondary text, hints, captions |
| `amber` | `#E9A23B` | same | The one accent: selection, beer, tint |
| `onAmber` | `#2B2118` | same | Text and icons on amber |
| `glassRim`, `glassInside`, `foam` | | | Drawing the glass; also placeholder numerals (`glassRim`) |

Use `.taproomScreen()` (or the same three modifiers) on a screen's root to set the
background, ink and amber tint.

## Type

System font throughout (SF Pro), so Dynamic Type works.

- **Titles and hero numbers:** heavy weight with slightly tight tracking. Beer names are
  `.system(size: 26, weight: .heavy)` with tracking −0.4; hero numbers such as the rating
  are 64pt heavy, monospaced digits, tracking −1.5.
- **Section labels:** `Taproom.sectionLabel` (footnote, bold), in sentence case:
  "Serving", "Where", "With". No uppercase grouped-list headers.
- **Secondary text:** subheadline or footnote in `Taproom.muted`, e.g. brewery above a beer
  name, or style and ABV below it.
- **Hints:** caption in `muted`, with a trailing arrow when they point at something
  (`TaproomTrailingIconLabel`).

## Layout and spacing

- `Taproom.margin` (16pt) side margins; `Taproom.sectionSpacing` (18pt) between sections;
  8pt between a section label and its content; 6pt between chips.
- Group a section as `TaproomSection("Title") { … }`.
- Long scrolling content goes in a `ScrollView` with `.scrollDismissesKeyboard(.interactively)`;
  the main action sits outside it in `.safeAreaInset(edge: .bottom) { … .taproomBottomBar() }`.
- Navigation bars are inline, with the background colour (`.toolbarBackground(Taproom.background, for: .navigationBar)`)
  and an `xmark` close button for full-screen covers.

## Components

| Piece | What it is | When to use it |
|---|---|---|
| `TaproomChip(on:)` | Capsule, 34pt tall; card with border, amber when selected | Picking one of a few options (serving style, venue). Use a `FlowLayout` for chips that wrap, or a horizontal `ScrollView` for one row. End a short list with a "…" chip that opens the full picker. |
| `TaproomChip(on: false, dashed: true)` | Dashed outline, no fill | An "add" action within a row of chips ("+ Tag friends") |
| `TaproomOutlineButton()` | Rounded rectangle (12pt), card fill, 1pt border, 44pt tall | Secondary actions, usually two side by side ("Camera" / "Photos") |
| `TaproomPrimaryButton()` | Full width, 54pt, ink fill, background-coloured text, 16pt corners | The screen's one main action, pinned at the bottom |
| `.taproomCard()` | Card fill, 1pt border, 16pt corners | Text fields, photos, tappable rows that need a boundary |
| `TaproomSection` | Bold label above content | Every titled block |
| `TaproomRating(rating:size:)` | The score in heavy type beside a small glass filled to match | Showing a checkin's rating (feed cards at 30, checkin screen at 44). Never stars. |
| `FilledGlass(rating:)` | A static pint glass filled to a rating, optional foam | Inside `TaproomRating`, and decoration (the login glass). `GlassRating` is the draggable one. |
| `BeerLabel(beer:brewery:size:)` | A beer's label, else its brewery's logo, else the app icon; Untappd's stock "default" badges count as none | Every beer image in a row, card or hero |
| `TaproomTabBar` | The app's bottom bar: tabs on the left, one dark context action on the right | Each tab's root screen, via `.safeAreaInset(edge: .bottom)`. Not on pushed screens, so it slides away on push; it hides itself while the keyboard is up. |
| `TaproomSearchField` | Card-style search field with Cancel; `focusRequests` focuses it from elsewhere | Searching or filtering on a page (Discover, a venue's menu) instead of `.searchable` |
| `TaproomRowStyle` + `.taproomRowDivider()` | Full-width tappable row with a pressed highlight, and a 1pt warm line under it | Lists laid out on the page: venues, beers, search results |
| `CardLinkStyle` | Dims a whole card a little while pressed | A card that opens something (feed cards, the "You're probably at" card) |

Existing shared views that already fit: `ServingIcon` (pass `color:` — amber normally,
`Taproom.onAmber` on an amber chip), `Avatar`, `FlowLayout`, `VenueRow`.

## Screen patterns

- **Tab bar.** The system tab bar is hidden. `TaproomTabBar` sits on each tab's root screen with
  Feed, Discover and Profile on the left and one context action on the right: **Search** on Feed
  and Profile (jumps to Discover and focuses its search field), **Scan** on Discover (opens the
  barcode scanner). Choosing the tab you're on scrolls it back to the top.
- **Lists of things to read** (the feed, a profile's checkins) are cards: `.taproomCard()` with the
  photo edge to edge inside, the rating as each card's hero on the right.
- **Lists of things to pick** (venues, beers, search results) are plain rows on the page with
  `TaproomRowStyle` and dividers, grouped under `TaproomSection`s. No `List`.
- **Detail screens** lead with their hero: the checkin's photo square and edge to edge under the
  navigation bar, with the content sheet overlapping it by 28pt (24pt top corners); without a
  photo, the label and a plain bar. A venue leads with its name in heavy type and its menu
  sections as chips.
- **Settings** use cards of switch rows (`Toggle` tinted amber), chips for multi-select options
  and tiles with previews for the theme.

## Motion and feedback

- Animate value changes with a quick interactive spring
  (`.interactiveSpring(response: 0.25, dampingFraction: 0.85)`).
- Give continuous controls a selection haptic on each step (`.sensoryFeedback(.selection, trigger:)`).
- Numbers that change in place use `.contentTransition(.numericText(value:))`.
- Decorative animation (like the glass's bubbles) runs only while the user is interacting,
  winds down shortly after, and is skipped when `accessibilityReduceMotion` is on.

## Accessibility

- Custom controls are real accessibility elements, with a label, value and hint, and
  `accessibilityAdjustableAction` for anything you drag (see `GlassRating`).
- Selected chips add the `.isSelected` trait; icon-only buttons get an `accessibilityLabel`.
- Hide purely decorative pieces (`accessibilityHidden(true)`).
- Check every screen in both light and dark mode; the Settings page can force either.

## Checklist for a redesigned screen

1. No `Form` or grouped `List` unless it's a long, plain list (a picker, search results).
2. Background, ink and tint from `Taproom`; no raw system colours.
3. One hero element; heavy title type; muted secondary text.
4. Sections are `TaproomSection`s; choices are `TaproomChip`s; the main action is a
   `TaproomPrimaryButton` in a bottom bar.
5. Works in light and dark, with Dynamic Type, VoiceOver and Reduce Motion.
