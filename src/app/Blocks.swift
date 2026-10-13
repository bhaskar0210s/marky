// Custom drawing for blocks and small inline pieces: code and quote backgrounds, rules, checkboxes
// and images. Everything is drawn on demand with dynamic colours, so it follows light and dark mode.

import AppKit

/// The background of a code block, quote or alert.
final class BackgroundBlock: NSTextBlock {
    enum Kind {
        case code(label: String)
        case quote
        case alert(NSColor)
    }

    let kind: Kind
    private let labelFont: NSFont

    init(kind: Kind, theme: Theme, indent: CGFloat) {
        self.kind = kind
        labelFont = NSFont.systemFont(ofSize: max(9, theme.size * 0.7), weight: .medium)
        super.init()
        let s = theme.size
        switch kind {
        case .code:
            setPadding(top: s * 0.75, bottom: s * 0.75, left: s * 0.95, right: s * 0.95)
        case .quote:
            setPadding(top: 0, bottom: 0, left: s * 1.05, right: 0)
        case .alert:
            setPadding(top: s * 0.6, bottom: s * 0.15, left: s * 1.1, right: s * 0.8)
        }
        setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        setWidth(theme.paragraphSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        // Without a width a block shrinks to nothing; 100% is what is left after margins and padding.
        setContentWidth(100, type: .percentageValueType)
    }

    // Blocks are never archived (copying writes plain text and RTF only); decline if asked.
    required init?(coder: NSCoder) { nil }

    /// Paragraph styles copy their blocks, and a copy made through NSTextBlock's initializer would
    /// skip this class's own properties. The block never changes after it is made, and consecutive
    /// paragraphs only form one block when they share the same object, so a copy is the block itself.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    private func setPadding(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        setWidth(top, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(bottom, type: .absoluteValueType, for: .padding, edge: .maxY)
        setWidth(left, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(right, type: .absoluteValueType, for: .padding, edge: .maxX)
    }

    override func drawBackground(withFrame bounds: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        // The frame includes the block's margins; the background goes inside them.
        let left = width(for: .margin, edge: .minX), right = width(for: .margin, edge: .maxX)
        let top = width(for: .margin, edge: .minY), bottom = width(for: .margin, edge: .maxY)
        let frameRect = NSRect(x: bounds.minX + left, y: bounds.minY + top,
                               width: bounds.width - left - right, height: bounds.height - top - bottom)
        switch kind {
        case .code(let label):
            Theme.codeBackground.setFill()
            NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
            if !label.isEmpty {
                let text = NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: Theme.tertiaryText])
                let size = text.size()
                text.draw(at: NSPoint(x: frameRect.maxX - size.width - 10, y: frameRect.minY + 6))
            }
        case .quote:
            Theme.rule.setFill()
            NSBezierPath(roundedRect: NSRect(x: frameRect.minX, y: frameRect.minY, width: 3, height: frameRect.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
        case .alert(let color):
            let box = NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8)
            color.withAlphaComponent(0.08).setFill()
            box.fill()
            // The accent bar follows the box's rounded corners.
            NSGraphicsContext.saveGraphicsState()
            box.addClip()
            color.setFill()
            NSRect(x: frameRect.minX, y: frameRect.minY, width: 3.5, height: frameRect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// A horizontal rule across the text column.
final class RuleCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { NSSize(width: 1, height: 1) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(1, lineFrag.width - position.x - textContainer.lineFragmentPadding), height: 1)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        Theme.rule.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.midY - 0.5, width: cellFrame.width, height: 1).fill()
    }

    override func wantsToTrackMouse() -> Bool { false }
    override func accessibilityLabel() -> String? { "Separator" }
}

/// A task list checkbox.
final class CheckboxCell: NSTextAttachmentCell {
    let checked: Bool
    let side: CGFloat

    init(checked: Bool, size: CGFloat) {
        self.checked = checked
        side = (size * 0.9).rounded()
        super.init(textCell: "")
    }

    // Cells are never archived; a decoded one is an empty, unchecked box rather than a crash.
    required init(coder: NSCoder) {
        checked = false
        side = 14
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize { NSSize(width: side, height: side) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -side * 0.16) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let box = cellFrame.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: box, xRadius: side * 0.24, yRadius: side * 0.24)
        if checked {
            NSColor.controlAccentColor.setFill()
            path.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + box.width * 0.24, y: box.minY + box.height * 0.53))
            tick.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.71))
            tick.line(to: NSPoint(x: box.minX + box.width * 0.77, y: box.minY + box.height * 0.3))
            tick.lineWidth = max(1.5, side * 0.12)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            Theme.tertiaryText.setStroke()
            path.lineWidth = 1.25
            path.stroke()
        }
    }

    override func wantsToTrackMouse() -> Bool { false }
    override func accessibilityLabel() -> String? { checked ? "Done" : "Not done" }
}

/// An alert's icon. On screen the symbol is drawn as is; printing and PDF export get a sharp
/// bitmap of it, because coloured symbol images do not survive in PDF contexts.
final class SymbolCell: NSTextAttachmentCell {
    let symbol: NSImage
    let label: String

    /// Symbol images are costly to make (each builds its own vector paths), so each one is made once.
    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor
    init?(name: String, color: NSColor, pointSize: CGFloat, label: String) {
        let key = "\(name)|\(pointSize)|\(color.hashValue)"
        if let image = SymbolCell.images[key] {
            symbol = image
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
                .withSymbolConfiguration(configuration) else { return nil }
            if SymbolCell.images.count > 32 { SymbolCell.images.removeAll() }
            SymbolCell.images[key] = image
            symbol = image
        }
        self.label = label
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        symbol = NSImage()
        label = ""
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize { symbol.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -symbol.size.height * 0.18) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if NSGraphicsContext.current?.isDrawingToScreen ?? true {
            symbol.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cellFrame.width * scale),
                                         pixelsHigh: Int(cellFrame.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return }
        // In points, so the context draws the symbol at its own size into the larger bitmap.
        rep.size = cellFrame.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: .zero, size: cellFrame.size))
        NSGraphicsContext.restoreGraphicsState()
        rep.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func wantsToTrackMouse() -> Bool { false }
    override func accessibilityLabel() -> String? { label }
}

/// An image, scaled down to fit the column.
final class ImageCell: NSTextAttachmentCell {
    let picture: NSImage

    init(picture: NSImage) {
        self.picture = picture
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        picture = NSImage()
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize { picture.size }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let natural = picture.size
        let available = max(16, lineFrag.width - position.x - 2 * textContainer.lineFragmentPadding)
        let scale = min(1, available / max(1, natural.width))
        return NSRect(x: 0, y: 0, width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// Draws the rounded backgrounds of inline code and highlights, sized to the text rather than
/// the whole line, beneath the selection.
final class ReaderLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            for (key, color) in [(NSAttributedString.Key.markyCode, Theme.codeBackground), (.markyHighlight, Theme.highlight)] {
                storage.enumerateAttribute(key, in: characters) { value, range, _ in
                    guard value != nil else { return }
                    drawRoundedBackground(for: range, color: color, storage: storage, container: container, origin: origin)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawRoundedBackground(for range: NSRange, color: NSColor, storage: NSTextStorage,
                                       container: NSTextContainer, origin: NSPoint) {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
        color.setFill()
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let piece = NSIntersectionRange(glyphs, lineGlyphs)
            guard piece.length > 0 else { return }
            var bounds = self.boundingRect(forGlyphRange: piece, in: container)
            let baseline = lineRect.minY + self.location(forGlyphAt: piece.location).y
            bounds.origin.y = baseline - font.ascender - 1.5
            bounds.size.height = font.ascender - font.descender + 3
            bounds = bounds.insetBy(dx: -2.5, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
    }
}
