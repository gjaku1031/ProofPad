#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 vX.Y.Z" >&2
  exit 64
fi

TAG="$1"
VERSION="${TAG#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="gjaku1031/ProofPad"
RELEASE_DIR="$ROOT_DIR/dist/releases/$TAG"
UPDATE_DIR="$ROOT_DIR/dist/updates/$TAG"

if [[ "${TAG:0:1}" != "v" ]]; then
  echo "Use a release tag like v0.1.0" >&2
  exit 64
fi

cd "$ROOT_DIR"

PROJECT_VERSION="$(awk -F'"' '/CFBundleShortVersionString/ { print $2; exit }' project.yml)"
if [[ "$PROJECT_VERSION" != "$VERSION" ]]; then
  echo "project.yml version is $PROJECT_VERSION, but release tag is $TAG" >&2
  echo "Run: scripts/bump_version.sh $VERSION <build-number>" >&2
  exit 65
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 69
fi

APP_PATH="$("$ROOT_DIR/scripts/build_release.sh" | tail -n 1)"
"$ROOT_DIR/scripts/create_dmg.sh" "$APP_PATH" "$TAG" "$RELEASE_DIR"
"$ROOT_DIR/scripts/create_update_feed.sh" "$APP_PATH" "$TAG" "$UPDATE_DIR"

DMG_PATH="$RELEASE_DIR/ProofPad-$VERSION.dmg"
ZIP_PATH="$UPDATE_DIR/ProofPad-$VERSION.zip"
NOTES_PATH="$UPDATE_DIR/ProofPad-$VERSION.md"
APPCAST_PATH="$UPDATE_DIR/appcast.xml"

for file in "$DMG_PATH" "$ZIP_PATH" "$NOTES_PATH" "$APPCAST_PATH"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing release asset: $file" >&2
    exit 66
  fi
done

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" "$ZIP_PATH" "$NOTES_PATH" "$APPCAST_PATH" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "ProofPad $VERSION" --notes-file "$NOTES_PATH" --latest
else
  gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" "$NOTES_PATH" "$APPCAST_PATH" \
    --repo "$REPO" \
    --title "ProofPad $VERSION" \
    --notes-file "$NOTES_PATH" \
    --target "$(git rev-parse HEAD)" \
    --latest
fi

echo "Published $TAG to https://github.com/$REPO/releases/tag/$TAG"
