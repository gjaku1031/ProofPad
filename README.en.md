# ProofPad

[한국어](README.md)

ProofPad is a macOS PDF note app for marking exams and worksheets with a Wacom pen. It opens multiple PDFs in one window, lets you write directly on top of pages, and saves handwriting back into the PDF.

Handwriting is stored as PDF ink annotations. During editing, ProofPad keeps a lightweight stroke model and renders through Metal for low latency. The goal is a practical personal Preview replacement for grading and PDF annotation.

## Status

ProofPad is early software. The current distribution flow is optimized for personal use and local testing.

Developer ID signing and notarization are intentionally out of scope for now. If you install from a GitHub Release DMG, macOS may show a Gatekeeper warning on first launch.

## Features

- PDF-first saving with editable ProofPad ink annotations
- Wacom/tablet pen drawing with optional mouse rejection
- Pressure-aware strokes with configurable ink feel
- Hold-to-erase and hold-to-pan key mappings
- Straight-line snapping by holding the pen at the end of a stroke
- Tabs for multiple PDFs in one host window
- Single-page and two-page spread layouts, including cover-only first page
- Recent files and PDF tools on the home screen
- Blank A4 templates: plain, dot grid, lined, and math note
- Basic PDF page tools: append, delete, duplicate, and export
- Sparkle-based in-app update checks

## Install

Personal DMGs are published on GitHub Releases.

1. Download `ProofPad-<version>.dmg`
2. Open the DMG
3. Drag `ProofPad.app` into `/Applications`
4. If macOS blocks the first launch, right-click the app in Finder and choose `Open`

If needed, remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/ProofPad.app
```

## Homebrew

Homebrew is used for first install and manual update verification. In-app updates are handled by Sparkle.

```sh
brew install --cask gjaku1031/proofpad/proofpad
```

The cask uses `auto_updates true`, so use `--greedy` when explicitly testing Homebrew upgrades:

```sh
brew update
brew upgrade --cask --greedy proofpad
```

## In-App Updates

Use `ProofPad > Check for Updates...` or the home screen `Check for Updates...` button. Sparkle reads `appcast.xml` from the latest GitHub Release.

Sparkle requires the old and new app bundles to be signed with the same code signing identity. For personal distribution, ProofPad uses a local self-signed identity instead of Developer ID:

```sh
scripts/create_local_codesign_identity.sh
```

`CFBundleVersion` must increase for Sparkle to detect an update:

```text
0.1.6 (build 7) -> 0.1.7 (build 8)
```

Each GitHub Release includes:

```text
ProofPad-<version>.dmg
ProofPad-<version>.zip
ProofPad-<version>.md
appcast.xml
```

The DMG is for manual installation. The ZIP and `appcast.xml` are for Sparkle.

## Development

Requirements:

- macOS 13 or newer
- Xcode with the macOS SDK
- XcodeGen
- Metal toolchain

If the Metal toolchain is missing:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Build:

```sh
xcodegen
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug build
```

Test:

```sh
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug test
```

`ProofPad.xcodeproj` is generated. `project.yml` is the source of truth.

## Release

Bump the app version:

```sh
scripts/bump_version.sh <short-version> <build-number>
```

Build the release app:

```sh
scripts/build_release.sh
```

Create the DMG, Sparkle ZIP, appcast, and upload them to GitHub Releases:

```sh
scripts/publish_release.sh v<short-version>
```

The Sparkle private key is not stored in this repository. It lives in the macOS Keychain under the `ProofPad` account. The local code signing identity is stored in the login keychain as `ProofPad Local Release`.

## Layout

```text
ProofPad/
  App/          app delegate, entrypoint, menus
  Document/     NSDocument, PDF assembly, recent files
  Input/        tablet routing, key modes, stroke construction
  Rendering/    PDF pages, spread views, Metal renderer
  Tabs/         single-window tab host
  Tools/        pen, eraser, settings
  UI/           home screen, sidebar, toolbar, panels
  Updates/      Sparkle updater wiring

ProofPadTests/   unit tests
scripts/         release and update helper scripts
project.yml      XcodeGen project definition
```

## License

No license has been chosen yet. Add a `LICENSE` file before publishing this as open source.
