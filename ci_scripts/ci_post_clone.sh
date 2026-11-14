#!/bin/bash
# Run by Xcode Cloud after it clones the repository, before it builds anything. See RELEASING.md.
#
# The Xcode project isn't committed (it's generated from project.yml), so this makes it.
#
# It doesn't set the build number: Xcode Cloud sets it itself, to CI_BUILD_NUMBER, its own
# counter, replacing any CURRENT_PROJECT_VERSION set here.
set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

# Homebrew is on Xcode Cloud's machines. Skip its self-update, which takes minutes.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
brew install xcodegen

xcodegen generate
echo "Generated Retappd.xcodeproj"
