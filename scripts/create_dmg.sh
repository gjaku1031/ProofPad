#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/ProofPad.app vX.Y.Z [output-dir]" >&2
  exit 64
fi

APP_PATH="$1"
TAG="$2"
OUT_DIR="${3:-dist/releases/$TAG}"
VERSION="${TAG#v}"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Expected a .app bundle: $APP_PATH" >&2
  exit 66
fi

if [[ "${TAG:0:1}" != "v" ]]; then
  echo "Use a release tag like v0.1.0" >&2
  exit 64
fi

mkdir -p "$OUT_DIR"
DMG_PATH="$OUT_DIR/ProofPad-$VERSION.dmg"
STAGING_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/ProofPad.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "ProofPad $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

shasum -a 256 "$DMG_PATH"
echo "Wrote $DMG_PATH"
