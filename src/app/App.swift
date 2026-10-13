// The application: menus, zoom and what happens at launch.

import AppKit
import UniformTypeIdentifiers

enum Settings {
    private static let defaults = UserDefaults.standard

    static var zoom: CGFloat {
        get {
            let value = defaults.double(forKey: "Zoom")
            return value == 0 ? 1 : CGFloat(value)
        }
        set { defaults.set(Double(newValue), forKey: "Zoom") }
    }

    static var showsOutline: Bool {
        get { defaults.object(forKey: "ShowsOutline") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "ShowsOutline") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let zoomSteps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    private let recentMenu = NSMenu(title: "Open Recent")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ReaderWindowController.open(url) }
    }

    // AppKit asks for an untitled document only when Marky starts (or is clicked in the Dock) with no
    // window to show. A reader has nothing to create, so it asks for a file instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openDocument(nil)
        return true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText]
        if let markdown = UTType("net.daringfireball.markdown") { types.insert(markdown, at: 0) }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { ReaderWindowController.open(url) }
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { ReaderWindowController.open(url) }
    }

    @objc func clearRecent(_ sender: Any?) {
        RecentFiles.clear()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for url in RecentFiles.urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.deletingLastPathComponent().path
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(zoomSteps.first { $0 > Settings.zoom + 0.01 } ?? Settings.zoom) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoomSteps.last { $0 < Settings.zoom - 0.01 } ?? Settings.zoom) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: CGFloat) {
        guard zoom != Settings.zoom else { return }
        Settings.zoom = zoom
        for controller in ReaderWindowController.all { controller.reader.refresh() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)): return Settings.zoom < zoomSteps.last!
        case #selector(zoomOut(_:)): return Settings.zoom > zoomSteps.first!
        case #selector(actualSize(_:)): return Settings.zoom != 1
        case #selector(clearRecent(_:)): return !RecentFiles.urls.isEmpty
        default: return true
        }
    }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Marky"

        let app = submenu(of: main, title: name)
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, title: "File")
        file.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        recentMenu.delegate = self
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recentMenu
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Reload", action: #selector(ReaderWindowController.reloadDocument(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Show in Finder", action: #selector(ReaderWindowController.revealInFinder(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: "Export as PDF…", action: #selector(ReaderWindowController.exportAsPDF(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Page Setup…", action: #selector(ReaderWindowController.runPageLayout(_:)), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Print…", action: #selector(ReaderWindowController.printDocument(_:)), keyEquivalent: "p")

        let edit = submenu(of: main, title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItems: [(String, String, NSTextFinder.Action, NSEvent.ModifierFlags)] = [
            ("Find…", "f", .showFindInterface, .command),
            ("Find Next", "g", .nextMatch, .command),
            ("Find Previous", "g", .previousMatch, [.command, .shift]),
            ("Use Selection for Find", "e", .setSearchString, .command),
        ]
        for (title, key, action, modifiers) in findItems {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
            item.keyEquivalentModifierMask = modifiers
        }
        find.addItem(withTitle: "Jump to Selection", action: #selector(NSTextView.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find

        let view = submenu(of: main, title: "View")
        view.addItem(withTitle: "Show Outline", action: #selector(ReaderWindowController.toggleOutline(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        let zoomInAlias = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInAlias.isAlternate = true
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let window = submenu(of: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(of menu: NSMenu, title: String) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }
}

