# ProofPad

[English](README.en.md)

ProofPad는 시험지 PDF를 빠르게 채점하고 정리하기 위한 macOS PDF 노트 앱입니다. Wacom 펜으로 PDF 위에 직접 필기하고, 여러 PDF를 하나의 창에서 탭으로 다룹니다.

필기는 PDF 내부의 ink annotation으로 저장하고, 편집 중에는 별도의 stroke 모델을 Metal로 렌더링합니다. 목표는 수학 강사나 채점자가 Preview보다 빠르게 PDF를 열고, 표시하고, 저장할 수 있는 개인용 도구입니다.

## 상태

아직 초기 버전입니다. 개인 사용과 로컬 테스트를 기준으로 배포 흐름을 맞추고 있습니다.

공개 배포용 Developer ID signing/notarization은 아직 하지 않습니다. GitHub Release의 DMG를 내려받아 설치하는 개인용 흐름에서는 첫 실행 때 Gatekeeper 경고가 뜰 수 있습니다.

## 기능

- PDF-first 저장: ProofPad가 만든 ink annotation을 PDF 안에 저장
- Wacom/tablet 펜 필기와 선택적 마우스 입력 무시
- 압력 반응과 보정값을 조절할 수 있는 필기감 설정
- hold-to-erase, hold-to-pan 키 매핑
- 끝점에서 잠시 유지하면 직선으로 보정되는 line snap
- 하나의 윈도우 안에서 여러 PDF 탭 관리
- 한 페이지/두 페이지 펼침 보기, 표지 단독 보기
- 홈 화면의 최근 파일과 PDF 도구
- 빈 A4 노트 템플릿: plain, dot grid, lined, math note
- PDF 페이지 추가, 이미지 추가, 삭제, 복제, 내보내기
- Sparkle 기반 앱 내 업데이트 확인

## 설치

개인용 DMG는 GitHub Release에서 받을 수 있습니다.

1. `ProofPad-<version>.dmg` 다운로드
2. DMG 열기
3. `ProofPad.app`을 `/Applications`로 드래그
4. 처음 실행할 때 macOS가 막으면 Finder에서 앱을 우클릭한 뒤 `Open`

필요하면 quarantine 속성을 제거할 수 있습니다.

```sh
xattr -dr com.apple.quarantine /Applications/ProofPad.app
```

## Homebrew

Homebrew는 초기 설치와 수동 검증용 경로입니다. 실제 앱 내 업데이트는 Sparkle이 담당합니다.

```sh
brew install --cask gjaku1031/proofpad/proofpad
```

Homebrew로 강제 업데이트를 검증할 때는 cask에 `auto_updates true`가 있으므로 `--greedy`를 붙입니다.

```sh
brew update
brew upgrade --cask --greedy proofpad
```

## 앱 내 업데이트

앱에서 `ProofPad > Check for Updates...` 또는 홈 화면의 `Check for Updates...`를 누르면 Sparkle이 GitHub Release의 `appcast.xml`을 확인합니다.

Sparkle 업데이트는 이전 앱과 새 앱이 같은 코드서명 identity로 서명되어 있어야 합니다. 개인용 배포에서는 Developer ID 대신 로컬 self-signed identity를 한 번 만들어 사용합니다.

```sh
scripts/create_local_codesign_identity.sh
```

업데이트가 인식되려면 `CFBundleVersion`이 반드시 증가해야 합니다. 예:

```text
0.1.6 (build 7) -> 0.1.7 (build 8)
```

GitHub Release asset은 다음 파일을 포함합니다.

```text
ProofPad-<version>.dmg
ProofPad-<version>.zip
ProofPad-<version>.md
appcast.xml
```

DMG는 사람이 설치하는 파일이고, ZIP과 `appcast.xml`은 Sparkle 업데이트용입니다.

## 개발

필요한 도구:

- macOS 13 이상
- Xcode와 macOS SDK
- XcodeGen
- Metal toolchain

Metal toolchain이 없다면:

```sh
xcodebuild -downloadComponent MetalToolchain
```

빌드:

```sh
xcodegen
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug build
```

테스트:

```sh
xcodebuild -project ProofPad.xcodeproj -scheme ProofPad -configuration Debug test
```

`ProofPad.xcodeproj`는 생성물입니다. 소스 오브 트루스는 `project.yml`입니다.

## 릴리즈

버전 올리기:

```sh
scripts/bump_version.sh <short-version> <build-number>
```

Release 앱 빌드:

```sh
scripts/build_release.sh
```

DMG, Sparkle ZIP, appcast 생성 후 GitHub Release 업로드:

```sh
scripts/publish_release.sh v<short-version>
```

Sparkle private key는 저장소에 없습니다. macOS Keychain의 `ProofPad` account에 보관합니다. 코드서명 identity는 `ProofPad Local Release` 이름으로 login keychain에 보관합니다.

## 구조

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

## 라이선스

아직 라이선스를 정하지 않았습니다. 공개 오픈소스로 운영하기 전에 `LICENSE` 파일을 추가해야 합니다.
