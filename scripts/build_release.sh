#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/ProofPad.app"
LOCAL_IDENTITY="${PROOFPAD_CODE_SIGN_IDENTITY:-ProofPad Local Release}"

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

if security find-certificate -c "$LOCAL_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign \
    --force \
    --sign "$LOCAL_IDENTITY" \
    --options runtime \
    --entitlements "$ROOT_DIR/ProofPad/ProofPad.entitlements" \
    "$APP_PATH"
  echo "Signed release app with $LOCAL_IDENTITY"
else
  echo "ProofPad local signing identity not found; keeping Xcode's ad-hoc signature." >&2
  echo "Run scripts/create_local_codesign_identity.sh before publishing Sparkle updates." >&2
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

plutil -p "$APP_PATH/Contents/Info.plist" | rg 'CFBundleShortVersionString|CFBundleVersion|SUFeedURL|SUPublicEDKey|CFBundleIdentifier'

echo "$APP_PATH"
