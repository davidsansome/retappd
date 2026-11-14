#!/bin/bash
# Run by Xcode Cloud after it clones the repository, before it builds anything. See RELEASING.md.
#
# The Xcode project isn't committed (it's generated from project.yml), so this makes it, and sets
# the build number to main's commit count, the same as the old GitHub Actions workflow did.
set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

# Homebrew is on Xcode Cloud's machines. Skip its self-update, which takes minutes.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
brew install xcodegen

# The build number has to go up with every upload, so it needs the whole history. A shallow clone
# would count too few commits and App Store Connect would refuse the build.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch --unshallow --quiet
fi
build=$(git rev-list --count HEAD)
[ "$build" -gt 1 ] || { echo "Build number $build looks wrong: is the history complete?" >&2; exit 1; }

# project.yml has the placeholder build number; this checkout is thrown away afterwards.
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) .*/\1 \"$build\"/" project.yml
grep -q "CURRENT_PROJECT_VERSION: \"$build\"" project.yml \
  || { echo "Couldn't set CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }

xcodegen generate
echo "Generated Retappd.xcodeproj: build $build"
