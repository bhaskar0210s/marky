// A reader window: an optional outline of the headings beside the document.

import AppKit

@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Every open reader, so a file opened twice brings its window forward instead.
    private(set) static var all: [ReaderWindowController] = []
    /// Readers still in memory, closed or not; the self-test checks that closing one frees it.
    nonisolated(unsafe) static var alive = 0

    let url: URL
    let reader = ReaderView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
    private(set) var text = ""
    private var watcher: FileWatcher?
    /// The outline and its split view are made the first time the outline is shown.
    private var outline: OutlineViewController?
    private var split: NSSplitViewController?
    private var sidebar: NSSplitViewItem?

    /// Opens a file in a window of its own, or brings its window forward if it is already open.
    @discardableResult
    static func open(_ url: URL) -> ReaderWindowController? {
        let url = url.absoluteURL.standardizedFileURL
        if let open = all.first(where: { $0.url == url }) {
            open.showWindow(nil)
            return open
        }
        guard let text = MarkdownFile.read(url) else {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” can’t be opened."
            alert.informativeText = "Marky could not read the file. It may have been moved, or you may not have permission to read it."
            alert.runModal()
            return nil
        }
        let controller = ReaderWindowController(url: url, text: text)
        all.append(controller)
        RecentFiles.add(url)
        controller.showWindow(nil)
        return controller
    }

    private init(url: URL, text: String) {
        self.url = url
        self.text = text
        // A plain title bar: content running under it would make macOS blur it, which costs a
        // second set of window-sized surfaces.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 380, height: 320)
        window.tabbingMode = .automatic
        window.titlebarSeparatorStyle = .automatic
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.contentView = reader
        super.init(window: window)

        ReaderWindowController.alive += 1
        window.delegate = self
        shouldCascadeWindows = true
        windowFrameAutosaveName = "Reader"
        if Settings.showsOutline { showOutline() }

        reader.show(text, baseURL: url.deletingLastPathComponent(), keepingPosition: false)
        window.makeFirstResponder(reader.textView)
        watcher = FileWatcher(url: url) { [weak self] in self?.reloadFromDisk() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        ReaderWindowController.alive -= 1
        // The window's memory is free only now; hand it back.
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }

    /// Shows the file again if it changed on disk, keeping the reading position.
    func reloadFromDisk() {
        guard let fresh = MarkdownFile.read(url), fresh != text else { return }
        text = fresh
        reader.show(text, baseURL: url.deletingLastPathComponent(), keepingPosition: true)
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        // Give the memory back as soon as the window goes. AppKit keeps the last closed window
        // around for a while, so its views (and the layers and surfaces behind them) go now.
        reader.releaseCaches()
        outline?.entries = []
        text = ""
        ReaderWindowController.all.removeAll { $0 === self }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.contentViewController = nil
            window.contentView = nil
            self.split = nil
            self.sidebar = nil
            self.outline = nil
        }
    }

    // MARK: Actions

    @objc func reloadDocument(_ sender: Any?) {
        watcher?.resume()
        guard let fresh = MarkdownFile.read(url) else {
            NSSound.beep()
            return
        }
        text = fresh
        reader.show(text, baseURL: url.deletingLastPathComponent(), keepingPosition: true)
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        let operation = PrintableText.operation(text: text, baseURL: url.deletingLastPathComponent(), info: NSPrintInfo.shared,
                                                title: url.deletingPathExtension().lastPathComponent)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func runPageLayout(_ sender: Any?) {
        guard let window else { return }
        NSPageLayout().beginSheet(using: NSPrintInfo.shared, on: window, completionHandler: nil)
    }

    @objc func exportAsPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let target = panel.url else { return }
            let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target
            let operation = PrintableText.operation(text: self.text, baseURL: self.url.deletingLastPathComponent(),
                                                    info: info, title: target.deletingPathExtension().lastPathComponent)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleOutline(_:)) {
            menuItem.title = (sidebar.map { !$0.isCollapsed } ?? false) ? "Hide Outline" : "Show Outline"
        }
        return true
    }

    // MARK: Outline

    @objc func toggleOutline(_ sender: Any?) {
        if let sidebar, !sidebar.isCollapsed {
            setCollapsed(sidebar, true)
        } else {
            showOutline()
        }
        Settings.showsOutline = !(sidebar?.isCollapsed ?? true)
    }

    /// Slides the sidebar in or out, or simply shows or hides it with Reduce Motion on.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed = collapsed
        } else {
            item.animator().isCollapsed = collapsed
        }
    }

    private func showOutline() {
        if let sidebar {
            setCollapsed(sidebar, false)
            return
        }
        guard let window else { return }
        let outline = OutlineViewController()
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: outline)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 340
        sidebar.canCollapse = true
        let content = NSViewController()
        let frame = window.frame
        window.contentView = nil
        content.view = reader
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "ReaderSplit"
        window.contentViewController = split
        window.setFrame(frame, display: true)
        outline.entries = reader.outline
        reader.onOutlineChange = { [weak outline] entries in outline?.entries = entries }
        reader.onCurrentHeadingChange = { [weak outline] index in outline?.highlight(index) }
        outline.onSelect = { [weak self] entry in
            self?.reader.scroll(toLocation: entry.location)
            self?.window?.makeFirstResponder(self?.reader.textView)
        }
        self.outline = outline
        self.split = split
        self.sidebar = sidebar
    }
}

/// The list of headings in the sidebar.
@MainActor
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((OutlineEntry) -> Void)?
    var entries: [OutlineEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            let top = entries.map(\.level).min() ?? 1
            // Three levels from the top one keeps long notes readable.
            rows = entries.indices.filter { entries[$0].level <= top + 2 }
            topLevel = top
            if isViewLoaded { table.reloadData() }
        }
    }
    private var rows: [Int] = []
    private var topLevel = 1
    private let table = NSTableView()
    private var highlighting = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Heading"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Outline")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? OutlineCell ?? OutlineCell(identifier: identifier)
        let entry = entries[rows[row]]
        cell.configure(title: entry.title.isEmpty ? "Untitled" : entry.title, depth: entry.level - topLevel)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !highlighting, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        onSelect?(entries[rows[table.selectedRow]])
    }

    /// Selects the heading the reader is in without jumping the reader.
    func highlight(_ entryIndex: Int?) {
        guard isViewLoaded else { return }
        highlighting = true
        defer { highlighting = false }
        guard let entryIndex, let row = rows.lastIndex(where: { $0 <= entryIndex }) else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }
}

final class OutlineCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, depth: Int) {
        label.stringValue = title
        label.toolTip = title
        leading.constant = 4 + CGFloat(depth) * 12
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: depth == 0 ? .semibold : .regular)
        label.textColor = depth == 0 ? .labelColor : .secondaryLabelColor
    }
}
