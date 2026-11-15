#!/bin/zsh
# Launches the installed Debug build on a simulator, signed in to one of the test accounts.
#
#   scripts/launch-test-account.sh <simulator udid> [account number, default 1]
#
# The accounts live in test-accounts.local at the root of the main checkout (not a worktree),
# so every worktree shares one copy. It's gitignored. One account per line:
#
#   <username or email> <password>
#
# Blank lines and lines starting with # are skipped. Auto sign-in only happens when the app
# isn't already signed in; sign out first to switch account.
set -euo pipefail

udid=${1:?usage: $0 <simulator udid> [account number]}
n=${2:-1}

main_checkout=$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")
file="$main_checkout/test-accounts.local"
[[ -f $file ]] || { echo "No $file; see the comment at the top of $0." >&2; exit 1; }

line=$( (grep -v '^[[:space:]]*\(#\|$\)' "$file" || true) | sed -n "${n}p")
[[ -n $line ]] || { echo "No account $n in $file." >&2; exit 1; }
user=${line%% *}
pass=${line#* }

xcrun simctl terminate "$udid" com.davidsansome.retappd 2>/dev/null || true
# Skip the location prompt, which otherwise covers the screen on first launch.
xcrun simctl privacy "$udid" grant location com.davidsansome.retappd
xcrun simctl launch "$udid" com.davidsansome.retappd -autoLoginUsername "$user" -autoLoginPassword "$pass" >/dev/null
echo "Launched as $user"
