#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <short-version> <build-number>" >&2
  exit 64
fi

SHORT_VERSION="$1"
BUILD_NUMBER="$2"

if [[ ! "$SHORT_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Expected semantic version like 0.1.1" >&2
  exit 64
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Build number must be an integer" >&2
  exit 64
fi

perl -0pi -e "s/CFBundleShortVersionString: \"[^\"]+\"/CFBundleShortVersionString: \"$SHORT_VERSION\"/; s/CFBundleVersion: \"[^\"]+\"/CFBundleVersion: \"$BUILD_NUMBER\"/" project.yml
xcodegen

echo "Set ProofPad version to $SHORT_VERSION ($BUILD_NUMBER)"
