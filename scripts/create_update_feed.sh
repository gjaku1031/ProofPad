#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/ProofPad.app vX.Y.Z [output-dir]" >&2
  exit 64
fi

APP_PATH="$1"
TAG="$2"
OUT_DIR="${3:-dist/updates/$TAG}"
VERSION="${TAG#v}"
REPO_URL="https://github.com/gjaku1031/ProofPad"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Expected a .app bundle: $APP_PATH" >&2
  exit 66
fi

if [[ "${TAG:0:1}" != "v" ]]; then
  echo "Use a release tag like v0.1.0" >&2
  exit 64
fi

if [[ -z "${SPARKLE_BIN:-}" ]]; then
  CANDIDATE="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
      -type f -print 2>/dev/null | sort | tail -n 1
  )"
  if [[ -z "$CANDIDATE" ]]; then
    echo "Could not find Sparkle tools. Build the project once, or set SPARKLE_BIN." >&2
    exit 69
  fi
  SPARKLE_BIN="$(dirname "$CANDIDATE")"
fi

GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "generate_appcast is not executable: $GENERATE_APPCAST" >&2
  exit 69
fi

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/ProofPad-$VERSION.zip"
NOTES="$OUT_DIR/ProofPad-$VERSION.md"

rm -f "$ARCHIVE" "$NOTES"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE"
printf '# ProofPad %s\n\nSee the GitHub release notes for changes.\n' "$VERSION" > "$NOTES"

"$GENERATE_APPCAST" \
  --account ProofPad \
  --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
  --release-notes-url-prefix "$REPO_URL/releases/download/$TAG/" \
  "$OUT_DIR"

echo "Wrote $ARCHIVE"
echo "Wrote $OUT_DIR/appcast.xml"
