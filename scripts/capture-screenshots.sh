#!/usr/bin/env bash
# Captures all 6 App Store demo screenshots on dedicated iPhone and iPad simulators,
# then frames them via scripts/make-screenshots.swift.
#
# Usage:
#   scripts/capture-screenshots.sh <iphone-udid> <ipad-udid> [app-path] [output-dir]

set -euo pipefail

IPHONE_UDID="${1:?Usage: $0 <iphone-udid> <ipad-udid> [app-path] [output-dir]}"
IPAD_UDID="${2:?Usage: $0 <iphone-udid> <ipad-udid> [app-path] [output-dir]}"
APP_PATH="${3:-.build/screenshots/Build/Products/Debug-iphonesimulator/Retappd.app}"
OUT_DIR="${4:-screenshots}"
RAW_DIR="${OUT_DIR}/raw"
BUNDLE_ID="com.davidsansome.retappd"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_SRC="${SCRIPT_DIR}/screenshot-assets"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

capture_device() {
  local udid="$1"
  local label="$2"
  local dest="${RAW_DIR}/${label}"
  mkdir -p "$dest"

  echo "==> Installing on ${label} (${udid})..."
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP_PATH"
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$label" == "iphone" ]]; then
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  else
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  fi

  local data_dir
  data_dir="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)"
  mkdir -p "${data_dir}/Library/Caches/screenshot-assets"
  cp "${ASSETS_SRC}"/*.jpg "${data_dir}/Library/Caches/screenshot-assets/"

  local specs=(
    "01-checkin:checkin:light"
    "02-feed:feed:light"
    "03-venue:venue:light"
    "04-beer:beer:light"
    "05-stats:stats:dark"
    "06-discover:discover:light"
  )

  local first=1
  for entry in "${specs[@]}"; do
    IFS=":" read -r name screen appearance <<< "$entry"
    echo "    Capturing ${label}/${name}.png (${screen}, ${appearance})..."
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl ui "$udid" appearance "$appearance"
    xcrun simctl launch "$udid" "$BUNDLE_ID" \
      -screenshotDemo \
      -screenshotScreen "$screen" \
      -screenshotAppearance "$appearance" >/dev/null
    if [[ "$first" -eq 1 ]]; then
      sleep "${CAPTURE_FIRST_WAIT:-6.0}"
      first=0
    else
      sleep "${CAPTURE_WAIT:-4.5}"
    fi
    xcrun simctl io "$udid" screenshot --type=png "${dest}/${name}.png" >/dev/null
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
}

capture_device "$IPHONE_UDID" "iphone"
capture_device "$IPAD_UDID" "ipad"

echo "==> Framing screenshots..."
swift "${SCRIPT_DIR}/make-screenshots.swift" "$RAW_DIR" "$OUT_DIR"
