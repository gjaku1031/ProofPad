# pdf-wacom

수학 강사의 시험지 PDF 채점이 주 시나리오인 macOS 노트앱. 와콤 펜으로 PDF 위에 그리고, 탭으로 여러 PDF를 동시에 다룬다.

## Build

xcodegen으로 프로젝트 생성 후 빌드:

```sh
xcodegen
xcodebuild -project pdf-wacom.xcodeproj -scheme pdf-wacom -configuration Debug build
```

`.metal` 파일이 있으므로 Metal Toolchain이 필요. 미설치 환경에선:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Commit message

소문자 type + 콜론(앞 붙임, 뒤 한 칸) + 한 줄 설명.

```
init: first commit
feat: 사이드바 토글 추가
fix: 펜 깜빡임 해결
refactor: tabBarView ownership 정리
docs: 좌표계 주석 보강
chore: gitignore 정리
```

타입: `feat` `fix` `refactor` `docs` `chore` `init`

## 핵심 결정

- **입력**: Wacom 펜만 그리기 (`NSEvent.subtype == .tabletPoint`). 마우스/트랙패드 차단.
- **펜 후미 자동 인식 X**. 임시 지우개는 ⌃ hold (Wacom 사이드 스위치를 Modifier→Control로 매핑).
- **두 페이지 보기 + 표지 단독** 옵션. 한 페이지 모드도 토글로 전환.
- **.pdfnote 패키지** 포맷 (`manifest.json` + `source.pdf` + `strokes/page-XXXX.bin`).
- **단일 호스트 윈도우**, 탭당 NSDocument 1개. 시스템 NSWindow tabbing은 사용 안 함.
- **Phase A (CAShapeLayer) + Phase B (Metal)** 둘 다 활성. baked stroke는 CAShapeLayer, live stroke만 Metal.

## 좌표계

Stroke 모델은 **PDF 페이지 좌표** (좌하단 원점, y-up, point 단위)로 저장 — 줌·뷰 크기 변경에 독립적.

view → page 변환은 `StrokeCanvasView.pagePoint(forViewPoint:)`, 역변환은 `viewPoint(forPagePoint:)`.

## Architecture (상위)

```
NSApplication
└── TabHostWindowController          단일 호스트 윈도우, 모든 도큐먼트 호스팅
    ├── NSToolbar                    펜 segment + Sidebar 토글 + Export
    ├── NSTitlebarAccessory          AppTabBarView (풀스크린에서 자동 숨김)
    └── HostContentViewController
        └── DocumentViewController   탭당 1개. NSSplitView(sidebar | content)
            ├── SidebarViewController 페이지 모드 토글 + 썸네일 그리드(NSCollectionView)
            └── SpreadStripView (NSScrollView documentView)
                └── SpreadView × N
                    └── PageView × 1~2
                        ├── PDFPageBackgroundView (PDF raster, background queue)
                        └── StrokeCanvasView      펜 입력 + 렌더
                            ├── bakedLayer (CAShapeLayer × N)
                            └── metalLiveLayer (CAMetalLayer)  ← Metal renderer
```

자세한 파일 단위 책임은 각 파일 상단 `// MARK:` 헤더 주석 참고.
