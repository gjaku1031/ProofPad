# ProofPad

ProofPad is a macOS PDF note app built for marking exams and worksheets with a Wacom pen.

The app stores handwriting directly in the PDF as ink annotations, while the editing session keeps a lightweight stroke model for low-latency rendering. The goal is a practical Preview replacement for people who grade, annotate, and reorganize PDFs all day.

## Status

ProofPad is early software. It is usable for local testing, but public distribution still needs Developer ID signing, notarization, and a first GitHub Release.

## Features

- PDF-first saving with editable ProofPad ink annotations
- Wacom/tablet pen input for drawing, with optional mouse rejection
- Smooth pressure-aware strokes with configurable ink feel
- Hold-to-erase and hold-to-pan key mappings
- Straight-line snapping by holding the pen at the end of a stroke
- Tabs for multiple PDFs in one host window
- Single-page and two-page spread layouts, including cover-only first page
- Recent files on the home screen
- Blank A4 note templates: plain, dot grid, lined, and math note
- Basic PDF page tools: append PDF pages, append images, delete, duplicate, and export
- Sparkle-based update checking through the app menu

## Requirements

- macOS 13 or newer
- Xcode with the macOS SDK
- XcodeGen
- Metal toolchain, because the renderer includes `.metal` shaders

If the Metal toolchain is missing:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Build

```sh
xcodegen
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug build
```

Run the test suite:

```sh
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug test
```

The generated `.xcodeproj` is intentionally ignored. `project.yml` is the source of truth.

## Updates

ProofPad uses [Sparkle 2](https://sparkle-project.org/documentation/). The app bundle contains:

- `SUFeedURL`: `https://github.com/gjaku1031/ProofPad/releases/latest/download/appcast.xml`
- `SUPublicEDKey`: the public EdDSA key for update archive verification
- `Check for Updates...` in the application menu

The private Sparkle key is not stored in this repository. It lives in the macOS Keychain under the `ProofPad` account.

For a release, build a signed/notarized app, create the update archive and appcast, then upload both to the GitHub Release:

```sh
scripts/create_update_feed.sh /path/to/ProofPad.app v0.1.0
```

That writes a ZIP archive and `appcast.xml` into `dist/updates/v0.1.0/`. Upload those files to the matching GitHub Release tag. For real public releases, the app should be Developer ID signed and notarized before the ZIP is generated.

## Project Layout

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
project.yml      XcodeGen project definition
```

## Notes

Stroke coordinates are stored in PDF page coordinates: lower-left origin, y-up, point units. That keeps annotations independent of zoom level and window size.

The app deliberately uses its own tab host instead of system window tabbing so PDF documents can share one toolbar/sidebar model.

## License

No license has been chosen yet. Add a `LICENSE` file before publishing this as open source.
