// Markdown files on disk: reading them, watching them for changes, printing them, and the list of
// recently opened ones.
//
// Marky does not use NSDocument: a reader never saves, and the document machinery keeps a private
// copy of the Launch Services database (5–13 MB) alive for as long as the app runs.

import AppKit

enum MarkdownFile {
    /// Bytes to text: UTF-8 (with or without a BOM), UTF-16 with a BOM, else Windows Latin-1.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The extensions Marky opens, Markdown first.
    static let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]
}

/// Files opened recently, newest first, for File > Open Recent.
@MainActor
enum RecentFiles {
    private static let key = "RecentFiles"
    private static let limit = 12

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// A text view laid out once at page width, for printing and PDF export.
@MainActor
enum PrintableText {
    static func make(text: String, baseURL: URL?, width: CGFloat) -> NSTextView {
        let storage = NSTextStorage()
        let layout = ReaderLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 1
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = ReaderTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        let renderer = Renderer(document: parseDocument(text), theme: Theme(zoom: 0.8), baseURL: baseURL, boxes: MathBoxCache())
        storage.setAttributedString(renderer.render())
        layout.ensureLayout(for: container)
        view.setFrameSize(NSSize(width: width, height: ceil(layout.usedRect(for: container).height)))
        return view
    }

    /// A print operation for the text, at the paper width of `info`.
    static func operation(text: String, baseURL: URL?, info base: NSPrintInfo, title: String) -> NSPrintOperation {
        let info = base.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let operation = NSPrintOperation(view: make(text: text, baseURL: baseURL, width: width), printInfo: info)
        operation.jobTitle = title
        return operation
    }
}

/// Watches one file. Editors often save by writing a new file and renaming it over the old one,
/// which ends the watch on the old file, so the watcher then reopens the path.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var attempts = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        attempts = Int.max
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return reopenLater() }
        attempts = 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename, .revoke],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.source else { return }
                if !current.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                    current.cancel()
                    self.source = nil
                    self.reopenLater()
                }
                self.changed()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Starts watching again if the file had gone away, e.g. after File > Reload.
    func resume() {
        guard source == nil, attempts != Int.max else { return }
        attempts = 0
        start()
    }

    /// A file that went away (a branch switch, a sync) is looked for quickly at first, then every
    /// two seconds for as long as the window is open.
    private func reopenLater() {
        guard attempts != Int.max else { return }
        attempts += 1
        let delay = attempts == 1 ? 0.05 : attempts < 40 ? 0.25 : 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.source == nil, self.attempts != Int.max else { return }
            self.start()
            if self.source != nil { self.changed() }
        }
    }

    /// Saves often arrive as several events; they are folded into one reload.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }
}
