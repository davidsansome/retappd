# Retappd

An iOS app (SwiftUI, iOS 18+) for Untappd, talking to Untappd's private v4 API the way the
official Android app does. The API is documented in the separate `untappd-private-api`
repository (`docs/API.md`, `docs/openapi.yaml`); check there before guessing an endpoint's
fields, and say so in a comment when something wasn't captured.

## Design

All screens use the **Taproom** style. Read [DESIGN.md](DESIGN.md) before building or changing
any UI, and use the shared pieces in `Retappd/Design/Taproom.swift` (palette, chips, buttons,
cards, sections, bottom bar) instead of system grouped lists, raw system colours or one-off
styles. The check-in screen (`Retappd/Features/CheckIn/CheckInSheet.swift`) is the reference.
When you need a new shared style, add it to `Taproom.swift` and describe it in DESIGN.md.

## Building

- The Xcode project is generated from `project.yml` and isn't committed. Run
  `xcodegen generate` after adding, removing or renaming files, and after pulling changes
  that do.
- Run the unit tests (`RetappdTests`) with `xcodebuild … test` before committing; CI doesn't
  run them.
- Info.plist keys (permission prompts and so on) are `INFOPLIST_KEY_…` settings in
  `project.yml`.

## Simulators

Each session creates and uses its own simulator, named after its task, and never touches
another session's: `xcrun simctl create "Untappd v2 <task>" "iPhone 18 Pro"`, boot it, and
pass its UDID to every simulator command. A new simulator isn't signed in to Untappd: ask the
user to sign in, and never enter their password.

## Releasing

Every push to `main` is built by Xcode Cloud and goes to TestFlight; see [RELEASING.md](RELEASING.md).
