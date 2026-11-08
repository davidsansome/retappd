#!/usr/bin/env bash
# Builds the app for App Store Connect: an archive, exported as an .ipa signed for distribution.
# Run by .github/workflows/ci.yml's testflight job:
#
#   scripts/archive.sh <build number> <output dir>
#
# It writes <output dir>/Retappd.ipa, and the archive beside it.
#
# There's no certificate on the runner, and none is ever made. The archive is built unsigned,
# and signed as it's exported by Xcode's cloud signing (-allowProvisioningUpdates), with a
# distribution certificate Apple keeps. Signing the archive itself, with automatic signing,
# would make a new development certificate on every run, as the runner has no private key.
#
# With ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (an App Store Connect API key, as on CI),
# Xcode signs in with that key; without them, with the Apple account signed in to Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."
build=$1
out=$2
archive="$out/Retappd.xcarchive"

auth=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_ID:-}" ]; then
  auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodegen generate --quiet
rm -rf "$archive"
mkdir -p "$out"
xcodebuild archive -project Retappd.xcodeproj -scheme Retappd \
  -destination generic/platform=iOS -archivePath "$archive" \
  -derivedDataPath build/DerivedData-archive \
  CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO

team=$(xcodebuild -project Retappd.xcodeproj -scheme Retappd -configuration Release \
  -showBuildSettings 2> /dev/null | sed -n 's/^ *DEVELOPMENT_TEAM = //p' | head -n 1)
[ -n "$team" ] || { echo "Couldn't read DEVELOPMENT_TEAM from the build settings" >&2; exit 1; }

cat > "$out/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$team</string>
  <!-- The build number is this script's. -->
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF
rm -rf "$out/export"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" "${auth[@]}"
mv "$out/export/"*.ipa "$out/Retappd.ipa"
rm -rf "$out/export"
echo "Built $out/Retappd.ipa: build $build"
