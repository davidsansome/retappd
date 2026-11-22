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
| `background` | `#FBF8F3` | `#17130E` | Screen background, nav bar; a wash over the tab bar's frosted glass |
| `card` | `#FFFFFF` | `#241E17` | Cards, fields, unselected chips |
| `border` | `#E7DDCE` | `#3A3128` | 1pt borders on cards, fields, chips |
| `ink` | `#2B2118` | `#F4ECDF` | Primary text; primary button fill |
| `muted` | `#6F6252` | `#B0A38F` | Secondary text, hints, captions |
| `amber` | `#E9A23B` | same | The one accent: selection, beer, tint |
| `onAmber` | `#2B2118` | same | Text and icons on amber |
| `had` | `#3B8449` | `#5CAE6B` | The "you've had this beer" corner; nothing else is green |
| `onHad` | `#FFFFFF` | `#0F2414` | The tick on `had` |
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
| `TaproomChip(on:)` | Capsule, 34pt tall; card with border, amber when selected | Picking one of a few options (serving style, venue). Use a `FlowLayout` for chips that wrap, or a horizontal `ScrollView` for one row. End a short list with a "…" chip that opens the full picker. Use `.taproomChipLabel(on:)` for `Menu` labels (Sort, Style filter chips) so they match `TaproomChip` |
| `TaproomEmptyFilterView` | Centered muted icon, headline, caption and "Clear filters" `TaproomOutlineButton` | When search or filter chips match no beers on a brewery or venue menu |
| `TaproomChip(on: false, dashed: true)` | Dashed outline, no fill | An "add" action within a row of chips ("+ Tag friends") when there's nothing to suggest |
| Suggestion chips | `TaproomChip` reading "+ Name" off, turning amber (with an avatar for people) when tapped; they stay in place | One-tap picks from a likely few (recently tagged friends, a beer's common flavours), ending in a "…" chip for the full list |
| `TaproomOutlineButton()` | Rounded rectangle (12pt), card fill, 1pt border, 44pt tall | Secondary actions, usually two side by side ("Camera" / "Photos") |
| `TaproomButtonRow` | A `Layout` for a row of outline buttons of different label lengths: fills the width, each button is its label's width plus the same extra, so padding is equal everywhere. Give labels `.padding(.horizontal, 4)`; mark icon-only buttons `.fixedInButtonRow()` | Photo row ("Camera" / "Last" / Photos); at large Dynamic Type the buttons shrink, so give labels an icon-only fallback with `ViewThatFits`, as the photo row does |
| `TaproomPrimaryButton()` | Full width, 54pt, ink fill, background-coloured text, 16pt corners | The screen's one main action, pinned at the bottom. `compact: true` makes it 44pt with 12pt corners, to sit beside `TaproomOutlineButton`s (Accept / Reject on a friend request) |
| `TaproomCountBadge(count:)` | Small amber capsule with a heavy count | Something waiting for you, beside a number (friend requests on the Me tab's Friends stat) |
| `.taproomCard()` | Card fill, 1pt border, 16pt corners | Text fields, photos, tappable rows that need a boundary |
| `TaproomSection` | Bold label above content | Every titled block |
| `TaproomRating(rating:size:)` | The score in heavy type beside a small glass filled to match | Showing a checkin's rating (feed cards at 30, checkin screen at 44). Never stars. |
| `FilledGlass(rating:)` | A static pint glass filled to a rating, optional foam | Inside `TaproomRating`, and decoration (the login glass). `GlassRating` is the draggable one. |
| `BeerLabel(beer:brewery:size:)` | A beer's label, else its brewery's logo, else the app icon; Untappd's stock "default" badges count as none | Every beer image in a row, card or hero |
| `TaproomTabBar` | The app's bottom bar: tabs on the left, one dark context action on the right | Each tab's root screen, via `.safeAreaInset(edge: .bottom)`. Not on pushed screens, so it slides away on push; it hides itself while the keyboard is up. Its background is frosted glass (`.ultraThinMaterial` under a wash of `background`), so the page shows through as it scrolls under. Put a `TaproomBarAction` in its action slot. At large text it degrades in steps instead of wrapping: first the action drops to its icon (the title stays its accessibility label), then the tabs drop to icons too (each tab keeps its accessibility label). Labels are one line and never clipped; every target stays at least 44pt. |
| `TaproomPageTabs` | Equal full-width tabs with an icon and heavy label; the selected one in ink over a 3pt ink underline, on a hairline that bleeds to the screen edges | Splitting one page into views of different kinds of thing (a venue's Menu and Check-ins). Chips go under it to narrow the selected tab; pin both under the navigation bar as a `LazyVStack` section header. Not for picking a value, which is what chips are for. |
| `TaproomLinkLabel` + `TaproomLinkStyle` | Text that opens another page: it keeps the surrounding text's look, with a small muted `chevron.right` (about 60% of the text size, growing with Dynamic Type) after the last line. The style adds no chrome, dims while pressed and stretches the touch target 10pt above and below the text without moving anything, so neighbouring links meet halfway | A beer's or brewery's name in a header (check-in screen, check-in page), as a `NavigationLink(value: BeerBreweryRoute…)`. On the check-in page the beer name has no chevron: the whole beer area (label, name, style line) is one link to the Beer page that just dims on press, and the brewery's `TaproomLinkLabel` is a link of its own inside it that wins the tap. The serving sits under the rating on the right, as on the feed card. Add `.accessibilityHint("Opens the beer's page")` and the `.isLink` trait. Drop the chevron (`showsChevron: false`) for a secondary line that shares its destination with the title |
| `TaproomStatsCard` | A card of up to four counts side by side, each a heavy number over a caption; nil counts are left out, or pass `isLoading: true` to show all titles with `.redacted(reason: .placeholder)` values while loading | The top of a detail page (a venue's, beer's or brewery's check-ins, people, this month, yours) |
| `TaproomLinkRow` | A row in a card that opens a web page or Maps: amber icon, content, and a muted "Website ↗" hint | Where, Find them: website, social accounts, map |
| `TaproomSegmented` | Bordered card of equal segments, the selected one amber; 44pt tall | Picking one value from a short row where the options are alike and switch the same content (a statistics range: 1W / 1M / 1Y / All). A value that matches no option shows no selection, which is how Statistics shows a custom date range. Not for splitting a page (`TaproomPageTabs`) or filtering (chips). |
| `TaproomStatRow` | Muted label left, heavy monospaced value right, 44pt | A table of figures inside a `.taproomCard()`, with a 1pt `border` line between rows (the statistics breakdown) |
| `TaproomSearchField` | Card-style search field with Cancel; `focusRequests` focuses it from elsewhere; `systemImage` swaps the magnifier (`location` for a "near…" field) and `capitalization` suits names of places | Searching or filtering on a page (Discover, a venue's menu) instead of `.searchable`. The shop picker stacks a second one, "Near… (city or country)", under the shop-name search |
| `TaproomOfflineSwitch` | "Offline" beside a switch tinted amber, bound to `Connectivity.offlineMode`; the label turns from muted to ink when on | The top right of screens that search or check in: above the search field on Discover, in the check-in screen's navigation bar. Only the user turns offline mode off, so nothing else flips it |
| `TaproomNotice` | A card with an amber icon, a bold subheadline title and a muted footnote message, with optional buttons under it (`TaproomOutlineButton` beside `TaproomPrimaryButton(compact: true)`) | Telling you about the app's state at the top of a page: "Offline mode is on" on Discover, and "The connection is slow" with Keep waiting / Go offline |
| `TaproomRowStyle` + `.taproomRowDivider()` | Full-width tappable row with a pressed highlight, and a 1pt warm line under it | Lists laid out on the page: venues, beers, search results |
| `CardLinkStyle` | Dims a whole card a little while pressed | A card that opens something (feed cards, the "You're probably at" card) |
| `HadCorner(size:)` | A green triangle with a tick in a corner (28pt default, top-right). Clip it to the owner's rounded corner | A beer the signed-in user has had: the top-right of a feed card (other people's checkins), and of the 44pt label in a `BeerRow` (18pt) |

Existing shared views that already fit: `ServingIcon` (pass `color:` — amber normally,
`Taproom.onAmber` on an amber chip), `Avatar`, `FlowLayout`, `VenueRow`, and
`CompactCheckinRow` (who and how long ago, the beer, a photo thumbnail and the rating on one
row) for lists of many checkins at one place, grouped under recency labels
(`RelativeTime.Bucket`: Last hour, Today, This week, Earlier).

## Screen patterns

- **Tab bar.** The system tab bar is hidden. `TaproomTabBar` sits on each tab's root screen with
  Activity, Discover and Me on the left and one context action on the right: **Search** on Activity
  and Me (jumps to Discover and focuses its search field), **Scan** on Discover (opens the
  barcode scanner). Choosing the tab you're on scrolls it back to the top.
- **Lists of things to read** (the feed, a profile's checkins) are cards: `.taproomCard()` with the
  photo edge to edge inside, the rating as each card's hero on the right.
- **Lists of things to pick** (venues, beers, search results) are plain rows on the page with
  `TaproomRowStyle` and dividers, grouped under `TaproomSection`s. No `List`.
- **Detail screens** lead with their hero: the checkin's photo square and edge to edge under the
  navigation bar, with the content sheet overlapping it by 28pt (24pt top corners); without a
  photo, the label and a plain bar. A venue leads with its name in heavy type and when it was last
  checked in at, then a stats card (Check-ins, People, This month, Yours), a "Where" card (address to Google Maps, website), and
  `TaproomPageTabs` for Menu (sections as chips) and Check-ins (Everyone / Friends chips).
  A beer leads with its brewery (a link), name, style / ABV / IBU and a 96pt label carrying the
  `HadCorner` if you've had it, then a card with everyone's rating beside yours (with a full-width
  Friends average row underneath when friends have rated it), a stats card,
  About (expandable), Flavours (passive chips) and recent check-ins as cards with an All / Friends
  `TaproomSegmented` toggle, with "Check in"
  pinned at the bottom (hidden when the page was opened from inside the check-in screen). A
  brewery leads with its name over its type and location beside its logo, then ratings, stats, About,
  "Find them" link rows, and `TaproomPageTabs` for Beers (`BeerRow`s, "Show N more") and Check-ins.
- **Badges.** Every badge in the app (the "Earned the … badge" line on a feed card, the rows under
  "Badges earned" on a check-in) opens its page with `NavigationLink(value: BeerBreweryRoute.badge…)`.
  The page leads with the badge's picture, name (without the earner's "(Level N)") and description,
  then the user's own level as the hero in a card with their avatar, then Friends: plain rows with
  dividers, each friend's level in heavy type on the right, "Show more" for the next 15.
- **Beer and brewery links.** Anywhere a beer or brewery is named in a header it links to its
  page with `NavigationLink(value: BeerBreweryRoute…)` and a `TaproomLinkLabel`; each
  `NavigationStack` has `.beerAndBreweryDestinations()` once on its root.
- **Statistics** (pushed from the Me tab) is the range buttons, a `‹ DATES ›` stepper, the totals, a bar
  chart in a card, the breakdown and top beers. The dates between the arrows are a button (ink text with
  a small `calendar` glyph) that opens a sheet: "From" and "To" cards (amber when being edited) over one
  graphical `DatePicker`, bounded by the first check-in and today, with Cancel (`TaproomOutlineButton`) and
  Done (`TaproomPrimaryButton(compact: true)`) pinned in a bottom bar. Done makes a custom range: no range
  button is selected, and the arrows step it by its own length. **Tap the chart** to show or hide each
  bar's unique-beer count (muted caption2 above the bar, ink and bold on the touched one; the choice is
  kept across launches; zero bars get none; crowded charts label every other bar or sparser so labels
  never touch, newest bar first). **Press and hold, then drag** to scrub: the totals switch to the
  touched bar and a haptic ticks per bar. VoiceOver gets a "Show/Hide values on bars" action.
- **Notifications** (pushed from the bell at the right of the Activity title; the bell carries a `TaproomCountBadge`
  when something is new, or an amber dot when only the app icon's badge is set) is a heavy title, a
  "Friend requests" row (amber icon, `TaproomCountBadge`, chevron; opens Me > Friends) only while requests are
  waiting, then plain `TaproomRowStyle` rows with dividers in a `LazyVStack`: the actor's avatar, one line of
  text with the names in semibold ("Jamie S and 2 others toasted your Late Nights III"), the short age in muted
  footnote, and the beer's `BeerLabel` (44pt) on the right, dropped at accessibility text sizes. Rows newer than
  what was last seen get a faint amber wash while the screen is open. Empty and error states use
  `ContentUnavailableView` and `ErrorRow`.
- **Friends** (pushed from the Friends stat on Me, which carries a small chevron) is a heavy
  title, then, only while incoming requests are waiting, a "Requests" `TaproomSection` above the
  search field: each row is the person (avatar, name, "@username · asked 2 hours ago", opening
  their profile) over an **Accept** (`TaproomPrimaryButton(compact: true)`) and **Reject**
  (`TaproomOutlineButton`) pair. Both answer at once and the row leaves; a failure puts only
  that request back with an alert. Reject has no confirmation because it is a silent decline the
  person can still be accepted from later (the add-friend sheet shows "You rejected their friend
  request." with Accept). When requests are waiting, the Friends stat on Me carries a
  `TaproomCountBadge` (amber capsule, count) at the number's top-right, on your own tab only.
  Below come a `TaproomSearchField`, then plain rows with dividers. Each row opens the profile and
  ends in a trailing "…" menu (a 44pt target, muted ellipsis, like the check-in cards') holding
  a destructive "Remove friend"; the row's chevron is dropped to make room. Destructive actions
  sit behind a `confirmationDialog` naming the person, and the row leaves the list at once,
  returning with an alert if the server refuses. The add-friend action is an icon button in the
  navigation bar, opening a sheet with a username field and a result card; the card shows
  "Add friend", or a muted line when they're already a friend, followed, or a request is pending
  either way ("Friend request sent. Waiting for them to accept."). When they asked you (waiting,
  or rejected by you), the muted line is followed by an Accept button.
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
