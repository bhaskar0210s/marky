// The reading area: a scrolling, read-only text view with a centred column.

import AppKit

@MainActor
final class ReaderView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: ReaderTextView
    private let storage = NSTextStorage()
    private let layoutManager = ReaderLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    private let boxes = MathBoxCache()
    private var theme = Theme(zoom: Settings.zoom)
    private var lastWidth: CGFloat = 0
    private(set) var outline: [OutlineEntry] = []
    /// The text on show, kept (rather than its parsed form, which is ten times larger) for re-renders.
    private var source: (text: String, baseURL: URL?)?

    /// Called with the outline after each render.
    var onOutlineChange: (([OutlineEntry]) -> Void)?
    /// Called with the index of the heading at the top of the view as it scrolls.
    var onCurrentHeadingChange: ((Int?) -> Void)?
    private var currentHeading: Int?
    private var scrollUpdatePending = false

    override init(frame: NSRect) {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        // Lay out only what is on screen, and only when it is needed: no work while idle.
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = false
        container.widthTracksTextView = true
        // Text blocks (code, quotes, alerts) stop after their first paragraph when this is zero.
        container.lineFragmentPadding = 1
        textView = ReaderTextView(frame: NSRect(origin: .zero, size: frame.size), textContainer: container)
        super.init(frame: frame)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.linkTextAttributes = [.foregroundColor: Theme.link, .cursor: NSCursor.pointingHand]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.setAccessibilityLabel("Document")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Rendering

    /// Shows Markdown text. On reloads the line at the top of the view stays where it was.
    func show(_ markdown: String, baseURL: URL?, keepingPosition: Bool) {
        source = (markdown, baseURL)
        let anchor = keepingPosition ? topAnchor() : nil
        let previous = keepingPosition ? storage.string : ""
        let document = parseDocument(markdown)
        let renderer = Renderer(document: document, theme: theme, baseURL: baseURL, boxes: boxes)
        let text = renderer.render()
        storage.setAttributedString(text)
        boxes.trim(keeping: document.math.count)
        outline = renderer.outline
        currentHeading = nil
        onOutlineChange?(outline)
        if let anchor {
            let location = ReaderView.mapLocation(anchor.location, from: previous, to: storage.string)
            restore(location: location, offset: anchor.offset)
        }
        updateCurrentHeading()
        ReaderView.returnFreeMemory()
    }

    /// Building the text makes many short-lived objects. Once it is on screen, hand the pages they
    /// used back to the system instead of keeping them for later.
    static func returnFreeMemory() {
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }

    /// Renders again, after a zoom or appearance change.
    func refresh() {
        guard let source else { return }
        // The anchor must be read before the column width changes and the text re-wraps.
        let anchor = topAnchor()
        let previousSize = theme.size
        theme = Theme(zoom: Settings.zoom)
        boxes.removeAll()
        updateInsets(force: true)
        show(source.text, baseURL: source.baseURL, keepingPosition: false)
        if let anchor {
            restore(location: anchor.location, offset: anchor.offset * theme.size / previousSize)
            updateCurrentHeading()
        }
    }

    func releaseCaches() {
        boxes.removeAll()
        storage.setAttributedString(NSAttributedString())
        source = nil
        ReaderView.returnFreeMemory()
    }

    override func layout() {
        super.layout()
        updateInsets(force: false)
    }

    /// Centres a column of at most `columnWidth` points, with a margin on narrow windows.
    private func updateInsets(force: Bool) {
        let width = scrollView.contentSize.width
        guard force || abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        let margin = (theme.size * 2).rounded()
        let horizontal = max(margin, ((width - theme.columnWidth) / 2).rounded()) - container.lineFragmentPadding
        textView.textContainerInset = NSSize(width: horizontal, height: (theme.size * 2.4).rounded())
    }

    // MARK: Position

    struct Anchor {
        let location: Int
        let offset: CGFloat
    }

    /// The character at the top of the view, and how far the view is scrolled past its line.
    private func topAnchor() -> Anchor? {
        guard storage.length > 0 else { return nil }
        let visible = scrollView.contentView.bounds
        guard visible.minY > 1 else { return nil }
        let origin = textView.textContainerOrigin
        let point = NSPoint(x: 1, y: visible.minY - origin.y + 1)
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return Anchor(location: layoutManager.characterIndexForGlyph(at: glyph), offset: visible.minY - (line.minY + origin.y))
    }

    private func restore(location: Int, offset: CGFloat) {
        guard storage.length > 0 else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, storage.length - 1))
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: max(0, line.minY + textView.textContainerOrigin.y + offset)))
    }

    /// Where a character of the old text is in the new one: unchanged before the edit,
    /// shifted after it, and at the start of the edit if it was inside it.
    static func mapLocation(_ location: Int, from old: String, to new: String) -> Int {
        let a = Array(old.utf16), b = Array(new.utf16)
        let shortest = min(a.count, b.count)
        var prefix = 0
        while prefix < shortest && a[prefix] == b[prefix] { prefix += 1 }
        if location < prefix { return location }
        var suffix = 0
        while suffix < shortest - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if location >= a.count - suffix { return location + (b.count - a.count) }
        return prefix
    }

    func scroll(toLocation location: Int, highlight: NSRange? = nil) {
        guard storage.length > 0 else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, storage.length - 1))
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = max(0, line.minY + textView.textContainerOrigin.y - theme.size)
        textView.scroll(NSPoint(x: 0, y: y))
        if let highlight { textView.showFindIndicator(for: highlight) }
    }

    func scroll(toAnchor anchor: String) {
        var found: NSRange?
        storage.enumerateAttribute(.markyAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? String) == anchor { found = range; stop.pointee = true }
        }
        guard let range = found else { NSSound.beep(); return }
        let trimmed = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
        scroll(toLocation: range.location, highlight: NSRange(location: range.location, length: (trimmed as NSString).length))
    }

    @objc private func didScroll() {
        guard !scrollUpdatePending else { return }
        scrollUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.scrollUpdatePending = false
            self?.updateCurrentHeading()
        }
    }

    private func updateCurrentHeading() {
        guard !outline.isEmpty else {
            if currentHeading != nil { currentHeading = nil; onCurrentHeadingChange?(nil) }
            return
        }
        let visible = scrollView.contentView.bounds
        let point = NSPoint(x: 1, y: visible.minY - textView.textContainerOrigin.y + theme.size * 3)
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        let index = outline.lastIndex { $0.location <= location }
        if index != currentHeading {
            currentHeading = index
            onCurrentHeadingChange?(index)
        }
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let anchor = link as? String {
            if anchor.hasPrefix("#") { scroll(toAnchor: String(anchor.dropFirst()).removingPercentEncoding ?? "") }
            return true
        }
        guard let url = link as? URL else { return false }
        if url.isFileURL {
            let readable = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]
            if readable.contains(url.pathExtension.lowercased()) {
                if let controller = ReaderWindowController.open(url.deletingFragment()), let fragment = url.fragment {
                    controller.reader.scroll(toAnchor: fragment.removingPercentEncoding ?? fragment)
                }
                return true
            }
            if !FileManager.default.fileExists(atPath: url.path) { NSSound.beep(); return true }
        }
        NSWorkspace.shared.open(url)
        return true
    }
}

private extension URL {
    func deletingFragment() -> URL {
        guard fragment != nil, var parts = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        parts.fragment = nil
        return parts.url ?? self
    }
}

/// The text view. Copying puts formulas on the clipboard as the LaTeX they were written in.
final class ReaderTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, .rtf] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let copied = NSMutableAttributedString()
        for (i, value) in selectedRanges.enumerated() {
            let range = value.rangeValue
            guard range.length > 0 else { continue }
            if i > 0 { copied.append(NSAttributedString(string: "\n")) }
            copied.append(ReaderTextView.copyable(storage.attributedSubstring(from: range)))
        }
        guard copied.length > 0 else { return false }
        pboard.declareTypes(types, owner: nil)
        var wrote = false
        if types.contains(.string) {
            wrote = pboard.setString(copied.string.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string) || wrote
        }
        if types.contains(.rtf), let rtf = copied.rtf(from: NSRange(location: 0, length: copied.length), documentAttributes: [:]) {
            wrote = pboard.setData(rtf, forType: .rtf) || wrote
        }
        return wrote
    }

    /// Replaces attachments with text: formulas with their source, checkboxes with [x] or [ ].
    static func copyable(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, String)] = []
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let math = attachment as? MathAttachment {
                replacements.append((range, math.source))
            } else if let box = attachment.attachmentCell as? CheckboxCell {
                replacements.append((range, box.checked ? "[x]" : "[ ]"))
            } else if attachment.attachmentCell is RuleCell {
                replacements.append((range, "———"))
            } else {
                replacements.append((range, ""))
            }
        }
        for (range, string) in replacements.reversed() {
            let attributes = result.attributes(at: range.location, effectiveRange: nil).filter { $0.key != .attachment }
            result.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attributes))
        }
        result.removeAttribute(.markyCode, range: NSRange(location: 0, length: result.length))
        result.removeAttribute(.markyHighlight, range: NSRange(location: 0, length: result.length))
        result.removeAttribute(.markyAnchor, range: NSRange(location: 0, length: result.length))
        return result
    }
}
