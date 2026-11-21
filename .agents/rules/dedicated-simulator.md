---
trigger: always_on
description: Every new untappd-v2 session creates its own fresh simulator and never reuses an existing one.
---

# Dedicated Simulator Per Session

For the `untappd-v2` iOS app, every new session creates a fresh simulator at the start and uses only that one. Never reuse an existing simulator, even one that looks idle.

- **How:** Run `xcrun simctl create "Untappd v2 <short session or branch name>" "iPhone 18 Pro"`, then `xcrun simctl boot <udid>`, and pass that UDID on every simulator call (`MobileBuildMCP` / `xcrun simctl`). Without an explicit device UDID, actions may target another session's booted simulator.
- **Why:** Prevents concurrent sessions from reinstalling/relaunching builds or sending taps to each other's simulators.
- **Signing in:** A new simulator isn't signed in to Untappd. Sign it in to a test account with `scripts/launch-test-account.sh <udid> [1|2]` (see `test-accounts.md`). Only for the user's real account, ask them to sign in themselves; never enter or ask for their password.
