#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/ProofPad.app"

cd "$ROOT_DIR"

xcodegen
xcodebuild \
  -project ProofPad.xcodeproj \
  -scheme ProofPad \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app was not created at $APP_PATH" >&2
  exit 70
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

plutil -p "$APP_PATH/Contents/Info.plist" | rg 'CFBundleShortVersionString|CFBundleVersion|SUFeedURL|SUPublicEDKey|CFBundleIdentifier'

echo "$APP_PATH"
