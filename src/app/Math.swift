// Typesets formulas with iosMath and draws them inside the text as attachments.

import AppKit
import iosMath
import Typeset

/// A typeset formula, or the reason it could not be typeset.
final class MathBox {
    let display: MTMathListDisplay?
    let error: String?
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// The appearance the formula's colour was last resolved for.
    var appearance: NSAppearance.Name?

    init(display: MTMathListDisplay) {
        self.display = display
        error = nil
        width = display.width
        ascent = display.ascent
        descent = display.descent
    }

    init(error: String, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        display = nil
        self.error = error
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

/// Owns the math font and the symbol tables; one per app.
@MainActor
final class MathEngine {
    static let shared = MathEngine()

    static let fontName = "latinmodern-math"
    private var fonts: [CGFloat: MTFont] = [:]
    let symbolCommands: [Unicode.Scalar: String]
    let commandSymbols: [String: String]

    private init() {
        MathEngine.registerExtras()
        // Map the Unicode characters behind iosMath's symbols back to their commands, so a
        // formula typed with "≤" or "α" reads as \le or \alpha. Shorter names win (\le over \leq).
        var forward: [String: String] = [:]
        var backward: [Unicode.Scalar: String] = [:]
        for name in MTMathAtomFactory.supportedLatexSymbolNames() {
            guard let atom = MTMathAtomFactory.atom(forLatexSymbol: name) else { continue }
            let nucleus = atom.nucleus
            guard !nucleus.isEmpty else { continue }
            forward[name] = nucleus
            let scalars = nucleus.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first, scalar.value > 127 {
                if let existing = backward[scalar], existing.count <= name.count { continue }
                backward[scalar] = name
            }
        }
        symbolCommands = backward
        commandSymbols = forward
    }

    func font(size: CGFloat) -> MTFont? {
        if let font = fonts[size] { return font }
        let font = MTFontManager.fontManager.font(withName: MathEngine.fontName, size: size)
        if fonts.count > 8 { fonts.removeAll() }
        fonts[size] = font
        return font
    }

    func typeset(_ tex: String, display: Bool, size: CGFloat) -> MathBox {
        guard let font = font(size: size) else {
            return errorBox("The math font is missing.", source: tex, size: size)
        }
        var reason: NSString?
        guard let line = MKTypeset(tex, font, display, &reason) else {
            return errorBox(reason as String? ?? "Unreadable formula", source: tex, size: size)
        }
        return MathBox(display: line)
    }

    private func errorBox(_ message: String, source: String, size: CGFloat) -> MathBox {
        let font = NSFont.monospacedSystemFont(ofSize: size * 0.72, weight: .regular)
        let width = (source as NSString).size(withAttributes: [.font: font]).width
        return MathBox(error: message, width: width + 6, ascent: font.ascender + 2, descent: -font.descender + 2)
    }

    /// Commands KaTeX users expect that iosMath lacks: negated relations, \rightsquigarrow and
    /// the number-set shorthands.
    private static func registerExtras() {
        let relations: [(String, String)] = [
            ("rightsquigarrow", "\u{21DD}"), ("leadsto", "\u{21DD}"), ("notni", "\u{220C}"),
            ("nequiv", "\u{2262}"), ("nsimeq", "\u{2244}"), ("napprox", "\u{2249}"), ("nsubset", "\u{2284}"),
            ("nsupset", "\u{2285}"), ("nless", "\u{226E}"), ("ngtr", "\u{226F}"), ("nleq", "\u{2270}"),
            ("ngeq", "\u{2271}"), ("nsim", "\u{2241}"), ("ncong", "\u{2247}"), ("nmid", "\u{2224}"),
            ("nparallel", "\u{2226}"), ("nvdash", "\u{22AC}"), ("nvDash", "\u{22AD}"), ("nprec", "\u{2280}"),
            ("nsucc", "\u{2281}"), ("npreceq", "\u{22E0}"), ("nsucceq", "\u{22E1}"),
            ("nleftarrow", "\u{219A}"), ("nrightarrow", "\u{219B}"), ("nleftrightarrow", "\u{21AE}"),
            ("nLeftarrow", "\u{21CD}"), ("nRightarrow", "\u{21CF}"), ("nLeftrightarrow", "\u{21CE}"),
            ("nsubseteq", "\u{2288}"), ("nsupseteq", "\u{2289}"), ("gets", "\u{2190}"),
        ]
        for (name, value) in relations where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.addLatexSymbol(name, value: MTMathAtom(type: .relation, value: value))
        }
        let ordinaries: [(String, String)] = [("nexists", "\u{2204}"), ("varnothing", "\u{2205}"), ("lnot", "\u{00AC}")]
        for (name, value) in ordinaries where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.addLatexSymbol(name, value: MTMathAtom(type: .ordinary, value: value))
        }
        let macros: [(String, String)] = [
            ("R", "\\mathbb{R}"), ("N", "\\mathbb{N}"), ("Z", "\\mathbb{Z}"), ("Q", "\\mathbb{Q}"),
            ("C", "\\mathbb{C}"), ("Reals", "\\mathbb{R}"), ("Complex", "\\mathbb{C}"), ("natnums", "\\mathbb{N}"),
        ]
        for (name, template) in macros where MTMathAtomFactory.macroDefinition(forCommand: name) == nil
            && MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.addMacro(name, argumentCount: 0, template: template)
        }
    }
}

/// The attachment that holds one formula. It typesets on first layout and draws as vectors.
final class MathAttachment: NSTextAttachment {
    /// The formula as written, for copying.
    let source: String

    init(source: String, cell: MathCell) {
        self.source = source
        super.init(data: nil, ofType: nil)
        attachmentCell = cell
    }

    // Attachments are never archived (copying writes plain text and RTF only); decline if asked.
    required init?(coder: NSCoder) { nil }
}

/// Draws a formula. Display formulas shrink to fit narrow windows; inline ones sit on the baseline.
final class MathCell: NSTextAttachmentCell {
    let tex: String
    let isDisplay: Bool
    let size: CGFloat
    private let boxes: MathBoxCache
    private var cachedBox: MathBox?

    init(tex: String, display: Bool, size: CGFloat, boxes: MathBoxCache) {
        self.tex = tex
        isDisplay = display
        self.size = size
        self.boxes = boxes
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        tex = ""
        isDisplay = false
        size = Theme.defaultSize
        boxes = MathBoxCache()
        super.init(coder: coder)
    }

    var box: MathBox {
        if let cachedBox { return cachedBox }
        let box = boxes.box(tex, display: isDisplay, size: size)
        cachedBox = box
        return box
    }

    /// Space around inline formulas; TeX adds none, but a hair keeps them off adjacent words.
    private var padding: CGFloat { isDisplay ? 0 : 1 }

    override func cellSize() -> NSSize {
        NSSize(width: ceil(box.width + 2 * padding), height: ceil(box.ascent + box.descent))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -box.descent)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let natural = cellSize()
        guard isDisplay, natural.width > lineFrag.width, lineFrag.width > 0 else {
            return NSRect(x: 0, y: -box.descent, width: natural.width, height: natural.height)
        }
        let scale = max(0.5, lineFrag.width / natural.width)
        return NSRect(x: 0, y: -box.descent * scale, width: natural.width * scale, height: natural.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let box = self.box
        let scale = min(1, cellFrame.width / max(1, cellSize().width))
        if let display = box.display {
            let appearance = NSAppearance.currentDrawing().name
            if box.appearance != appearance {
                display.textColor = NSColor.labelColor
                box.appearance = appearance
            }
            context.saveGState()
            // The text view is flipped; iosMath draws upwards from the baseline.
            context.translateBy(x: cellFrame.minX + padding * scale, y: cellFrame.maxY - box.descent * scale)
            context.scaleBy(x: scale, y: -scale)
            // A flipped view also flips the text matrix, which would turn the glyphs upside down.
            context.textMatrix = .identity
            display.position = .zero
            display.draw(context)
            context.restoreGState()
        } else {
            // A formula that could not be typeset is shown as written, in red, like KaTeX does.
            let font = NSFont.monospacedSystemFont(ofSize: size * 0.72, weight: .regular)
            let text = NSAttributedString(string: tex, attributes: [.font: font, .foregroundColor: NSColor.systemRed])
            text.draw(at: NSPoint(x: cellFrame.minX + 3, y: cellFrame.minY + 2))
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }

    // VoiceOver reads a formula as the LaTeX it was written in.
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Formula: " + tex }
}

/// Typeset formulas for one window, kept across reloads so only edited formulas are redone.
@MainActor
final class MathBoxCache {
    private var boxes: [String: MathBox] = [:]

    func box(_ tex: String, display: Bool, size: CGFloat) -> MathBox {
        let key = "\(display ? "D" : "I")\(size)|\(tex)"
        if let box = boxes[key] { return box }
        let box = MathEngine.shared.typeset(tex, display: display, size: size)
        boxes[key] = box
        return box
    }

    /// Drops formulas no longer in the document once the cache has grown well past it.
    func trim(keeping formulas: Int) {
        if boxes.count > max(256, formulas * 2) { boxes.removeAll(keepingCapacity: false) }
    }

    func removeAll() {
        boxes.removeAll(keepingCapacity: false)
    }
}
