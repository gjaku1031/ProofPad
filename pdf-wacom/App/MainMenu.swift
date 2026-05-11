import Cocoa

enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeWindowMenu())
        return mainMenu
    }

    private static func makeAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "About pdf-wacom",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide pdf-wacom",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit pdf-wacom",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        // ⌘T: 새 탭으로 열기 (Open dialog)
        let newTab = NSMenuItem(title: "New Tab…",
                                action: Selector(("newDocumentTab:")),
                                keyEquivalent: "t")
        newTab.keyEquivalentModifierMask = [.command]
        menu.addItem(newTab)

        // ⌘O: 표준 NSDocumentController open
        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")

        menu.addItem(.separator())

        // ⌘W: 활성 탭 닫기 (NSWindow.performClose 대신 host 액션)
        let closeTab = NSMenuItem(title: "Close Tab",
                                  action: Selector(("closeActiveTab:")),
                                  keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command]
        menu.addItem(closeTab)

        menu.addItem(withTitle: "Save",
                     action: #selector(NSDocument.save(_:)),
                     keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…",
                                action: #selector(NSDocument.saveAs(_:)),
                                keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)

        menu.addItem(.separator())
        let export = NSMenuItem(title: "Export Flattened PDF…",
                                action: Selector(("exportPDF:")),
                                keyEquivalent: "E")
        export.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(export)
        item.submenu = menu
        return item
    }

    private static func makeEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        // 도구 단축키 ⌃⌘1/2/3 (펜) ⌃⌘E (지우개)
        let pen1 = NSMenuItem(title: "Pen 1",
                              action: Selector(("selectPen1:")),
                              keyEquivalent: "1")
        pen1.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(pen1)
        let pen2 = NSMenuItem(title: "Pen 2",
                              action: Selector(("selectPen2:")),
                              keyEquivalent: "2")
        pen2.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(pen2)
        let pen3 = NSMenuItem(title: "Pen 3",
                              action: Selector(("selectPen3:")),
                              keyEquivalent: "3")
        pen3.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(pen3)
        let eraser = NSMenuItem(title: "Eraser",
                                action: Selector(("selectEraser:")),
                                keyEquivalent: "e")
        eraser.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(eraser)

        item.submenu = menu
        return item
    }

    private static func makeViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let goTo = NSMenuItem(title: "Go to Page…",
                              action: Selector(("goToPage:")),
                              keyEquivalent: "g")
        goTo.keyEquivalentModifierMask = [.command]
        menu.addItem(goTo)

        let toggleSidebar = NSMenuItem(title: "Toggle Sidebar",
                                       action: Selector(("toggleDocumentSidebar:")),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(toggleSidebar)

        menu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: Selector(("zoomIn:")),
                                keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        menu.addItem(zoomIn)

        let zoomInEq = NSMenuItem(title: "Zoom In (=)",
                                  action: Selector(("zoomIn:")),
                                  keyEquivalent: "=")
        zoomInEq.keyEquivalentModifierMask = [.command]
        zoomInEq.isAlternate = true
        zoomInEq.isHidden = true
        menu.addItem(zoomInEq)

        let zoomOut = NSMenuItem(title: "Zoom Out",
                                 action: Selector(("zoomOut:")),
                                 keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        menu.addItem(zoomOut)

        let resetZoom = NSMenuItem(title: "Fit Width",
                                   action: Selector(("fitWidth:")),
                                   keyEquivalent: "0")
        resetZoom.keyEquivalentModifierMask = [.command]
        menu.addItem(resetZoom)

        let fitHeight = NSMenuItem(title: "Fit Height",
                                   action: Selector(("fitHeight:")),
                                   keyEquivalent: "")
        menu.addItem(fitHeight)

        let fitPage = NSMenuItem(title: "Fit Page",
                                 action: Selector(("fitPage:")),
                                 keyEquivalent: "")
        menu.addItem(fitPage)

        let actual = NSMenuItem(title: "Actual Size",
                                action: Selector(("actualSize:")),
                                keyEquivalent: "")
        menu.addItem(actual)

        menu.addItem(.separator())

        let presentation = NSMenuItem(title: "Enter Presentation Mode",
                                      action: Selector(("togglePresentationMode:")),
                                      keyEquivalent: "f")
        presentation.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(presentation)

        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        let nextTab = NSMenuItem(title: "Next Tab",
                                 action: Selector(("nextTab:")),
                                 keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        menu.addItem(nextTab)

        let nextTabAlt = NSMenuItem(title: "Next Tab",
                                    action: Selector(("nextTab:")),
                                    keyEquivalent: "]")
        nextTabAlt.keyEquivalentModifierMask = [.command, .shift]
        nextTabAlt.isAlternate = true
        nextTabAlt.isHidden = true
        menu.addItem(nextTabAlt)

        let prevTab = NSMenuItem(title: "Previous Tab",
                                 action: Selector(("previousTab:")),
                                 keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(prevTab)

        let prevTabAlt = NSMenuItem(title: "Previous Tab",
                                    action: Selector(("previousTab:")),
                                    keyEquivalent: "[")
        prevTabAlt.keyEquivalentModifierMask = [.command, .shift]
        prevTabAlt.isAlternate = true
        prevTabAlt.isHidden = true
        menu.addItem(prevTabAlt)

        menu.addItem(.separator())

        // ⌘1 ~ ⌘9: N번째 탭 활성화 (host의 tabN: 액션)
        for i in 1...9 {
            let tabItem = NSMenuItem(title: "Tab \(i)",
                                     action: Selector(("tab\(i):")),
                                     keyEquivalent: "\(i)")
            tabItem.keyEquivalentModifierMask = [.command]
            menu.addItem(tabItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
