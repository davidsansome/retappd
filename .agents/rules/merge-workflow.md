---
trigger: always_on
description: Land finished work in untappd-v2 by rebasing onto main, fast-forwarding main, and pushing main (no PRs).
---

# Merge Workflow

In `untappd-v2`, finished work lands by rebasing the branch onto `main`, fast-forwarding `main` to it, and pushing `main` to `origin`. Do not open a PR or create merge commits.

- **How to apply:** When the user asks to land, merge, or ship a branch:
  1. `git fetch origin`
  2. Rebase the branch onto `origin/main`
  3. Fast-forward `main` (it is usually checked out in the main checkout, so check its working tree is clean first, then run `git -C <main-checkout> merge --ff-only <branch>`)
  4. `git push origin main`
- Still wait for the user to ask before pushing.
