---
trigger: always_on
description: Where the Untappd test account logins live and how to sign a fresh simulator in with them.
---

# Test Accounts

Two Untappd test accounts are available for signing in fresh simulators.

- **Location:** `/Users/david/untappd-v2/test-accounts.local` (at the main checkout root, not in a worktree; gitignored via `.gitignore` and `.git/info/exclude`; one `<username> <password>` per line).
- **Security:** Never copy passwords into memory, rules, commits, or chat.
- **Usage:** Install a Debug build on the simulator, then run:
  ```bash
  scripts/launch-test-account.sh <udid> [1|2]
  ```
  This launches the app with `-autoLoginUsername` / `-autoLoginPassword` (handled by `AuthStore.signInFromLaunchArguments`, Debug only, only when signed out).
