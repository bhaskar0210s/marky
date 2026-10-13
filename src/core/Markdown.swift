// Parses Markdown into a small document tree with md4c, after the scanner has set formulas aside.

import md4c

public indirect enum Inline: Equatable, Sendable {
    case text(String)
    case code(String)
    case math(Int)                 // index into Document.math
    case softBreak
    case hardBreak
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case highlight([Inline])
    case link(destination: String, title: String, content: [Inline])
    case wikiLink(target: String, content: [Inline])
    case image(source: String, title: String, alt: [Inline])
    case footnoteReference(id: Int, label: String)
    case html(String)
}

public enum Alignment: Equatable, Sendable {
    case none, left, center, right
}

public struct Table: Equatable, Sendable {
    public var alignments: [Alignment] = []
    public var header: [[Inline]] = []
    public var rows: [[[Inline]]] = []
}

public struct ListItem: Equatable, Sendable {
    /// nil for an ordinary item; true or false for a checked or unchecked task.
    public var task: Bool?
    public var blocks: [Block]
}

public struct List: Equatable, Sendable {
    public var ordered: Bool
    public var start: Int
    public var tight: Bool
    public var items: [ListItem]
}

public struct Footnote: Equatable, Sendable {
    public var id: Int
    public var label: String
    public var blocks: [Block]
}

public indirect enum Block: Equatable, Sendable {
    case paragraph([Inline])
    case heading(level: Int, content: [Inline])
    case quote([Block])
    case alert(kind: String, blocks: [Block])   // GitHub's > [!NOTE] and friends
    case list(List)
    case code(language: String, text: String)
    case html(String)
    case rule
    case table(Table)
    case math(Int)                               // a display formula on its own
    case frontMatter(String)
    case footnotes([Footnote])
}

public struct Document: Equatable, Sendable {
    public var blocks: [Block]
    public var math: [MathSpan]
}

/// GitHub's dialect (MD_DIALECT_GITHUB, spelled out because Swift cannot import that macro),
/// plus ==highlight== and [[wiki links]].
private let parserFlags = UInt32(MD_FLAG_PERMISSIVEURLAUTOLINKS | MD_FLAG_PERMISSIVEEMAILAUTOLINKS
    | MD_FLAG_PERMISSIVEWWWAUTOLINKS | MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS
    | MD_FLAG_ADMONITIONS | MD_FLAG_FOOTNOTES | MD_FLAG_HIGHLIGHT | MD_FLAG_WIKILINKS)

public func parseDocument(_ text: String) -> Document {
    let scanned = scan(text)
    let builder = TreeBuilder(math: scanned.math)
    builder.parse(scanned.markdown)
    var blocks = liftingDisplayMath(builder.result(), math: scanned.math)
    if let front = scanned.frontMatter {
        blocks.insert(.frontMatter(front), at: 0)
    }
    return Document(blocks: blocks, math: scanned.math)
}

// MARK: - md4c callbacks

private final class TreeBuilder {
    enum Kind {
        case document, quote, alert(String), list(ordered: Bool, start: Int, tight: Bool), item(task: Bool?)
        case paragraph, heading(Int), code(String), html, rule
        case table, tableHead, tableBody, row, cell(Alignment)
        case footnotes, footnote(id: Int, label: String)
    }

    struct Frame {
        var kind: Kind
        var blocks: [Block] = []
        var inlines: [Inline] = []
        var text = ""
        var items: [ListItem] = []
        var table = Table()
        var inHead = false
        var cells: [[Inline]] = []
        var aligns: [Alignment] = []
        var notes: [Footnote] = []
    }

    enum SpanKind {
        case emphasis, strong, strikethrough, highlight, plain
        case link(String, String), wikiLink(String), image(String, String), code
    }

    struct Span {
        var kind: SpanKind
        var inlines: [Inline] = []
        var code = ""
    }

    let math: [MathSpan]
    var frames: [Frame] = [Frame(kind: .document)]
    var spans: [Span] = []

    init(math: [MathSpan]) {
        self.math = math
    }

    func parse(_ markdown: String) {
        var parser = MD_PARSER(
            abi_version: 0,
            flags: parserFlags,
            enter_block: { type, detail, user in
                TreeBuilder.from(user).enterBlock(type, detail); return 0
            },
            leave_block: { type, _, user in
                TreeBuilder.from(user).leaveBlock(type); return 0
            },
            enter_span: { type, detail, user in
                TreeBuilder.from(user).enterSpan(type, detail); return 0
            },
            leave_span: { type, _, user in
                TreeBuilder.from(user).leaveSpan(type); return 0
            },
            text: { type, text, size, user in
                TreeBuilder.from(user).text(type, text, Int(size)); return 0
            },
            debug_log: nil,
            syntax: nil)
        var bytes = Array(markdown.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { chars in
                _ = md_parse(chars, MD_SIZE(buffer.count), &parser, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        if bytes.isEmpty { return }
    }

    func result() -> [Block] {
        // md4c always balances its callbacks; fold anything left open defensively.
        while frames.count > 1 { closeFrame() }
        flushInlines(&frames[0])
        return frames[0].blocks
    }

    static func from(_ user: UnsafeMutableRawPointer?) -> TreeBuilder {
        Unmanaged<TreeBuilder>.fromOpaque(user!).takeUnretainedValue()
    }

    // MARK: Blocks

    func enterBlock(_ type: MD_BLOCKTYPE, _ detail: UnsafeMutableRawPointer?) {
        if type == MD_BLOCK_DOC { return }
        flushInlines(&frames[frames.count - 1])
        var frame: Frame
        switch type {
        case MD_BLOCK_QUOTE:
            frame = Frame(kind: .quote)
        case MD_BLOCK_ADMONITION:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_ADMONITION_DETAIL.self).pointee
            frame = Frame(kind: .alert(attribute(d.type).lowercased()))
        case MD_BLOCK_UL:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_UL_DETAIL.self).pointee
            frame = Frame(kind: .list(ordered: false, start: 1, tight: d.is_tight != 0))
        case MD_BLOCK_OL:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_OL_DETAIL.self).pointee
            frame = Frame(kind: .list(ordered: true, start: Int(d.start), tight: d.is_tight != 0))
        case MD_BLOCK_LI:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_LI_DETAIL.self).pointee
            let task: Bool? = d.is_task != 0 ? (d.task_mark != CChar(UInt8(ascii: " "))) : nil
            frame = Frame(kind: .item(task: task))
        case MD_BLOCK_HR:
            frame = Frame(kind: .rule)
        case MD_BLOCK_H:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_H_DETAIL.self).pointee
            frame = Frame(kind: .heading(Int(d.level)))
        case MD_BLOCK_CODE:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_CODE_DETAIL.self).pointee
            frame = Frame(kind: .code(attribute(d.lang)))
        case MD_BLOCK_HTML:
            frame = Frame(kind: .html)
        case MD_BLOCK_P:
            frame = Frame(kind: .paragraph)
        case MD_BLOCK_TABLE:
            frame = Frame(kind: .table)
        case MD_BLOCK_THEAD:
            frame = Frame(kind: .tableHead)
        case MD_BLOCK_TBODY:
            frame = Frame(kind: .tableBody)
        case MD_BLOCK_TR:
            frame = Frame(kind: .row)
        case MD_BLOCK_TH, MD_BLOCK_TD:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_TD_DETAIL.self).pointee
            let align: Alignment
            switch d.align {
            case MD_ALIGN_LEFT: align = .left
            case MD_ALIGN_CENTER: align = .center
            case MD_ALIGN_RIGHT: align = .right
            default: align = .none
            }
            frame = Frame(kind: .cell(align))
        case MD_BLOCK_FOOTNOTE_DEF_SECTION:
            frame = Frame(kind: .footnotes)
        case MD_BLOCK_FOOTNOTE_DEF:
            let d = detail!.assumingMemoryBound(to: MD_BLOCK_FOOTNOTE_DEF_DETAIL.self).pointee
            frame = Frame(kind: .footnote(id: Int(d.id), label: attribute(d.label)))
        default:
            frame = Frame(kind: .quote)
        }
        frames.append(frame)
    }

    func leaveBlock(_ type: MD_BLOCKTYPE) {
        if type == MD_BLOCK_DOC || frames.count <= 1 { return }
        closeFrame()
    }

    func closeFrame() {
        // Spans never cross block boundaries, but fold any stragglers into the block.
        while !spans.isEmpty { closeSpan() }
        var frame = frames.removeLast()
        flushInlines(&frame)
        let parent = frames.count - 1
        switch frame.kind {
        case .document:
            frames[parent].blocks += frame.blocks
        case .quote:
            frames[parent].blocks.append(.quote(frame.blocks))
        case .alert(let kind):
            frames[parent].blocks.append(.alert(kind: kind, blocks: frame.blocks))
        case .list(let ordered, let start, let tight):
            frames[parent].blocks.append(.list(List(ordered: ordered, start: start, tight: tight, items: frame.items)))
        case .item(let task):
            frames[parent].items.append(ListItem(task: task, blocks: frame.blocks))
        case .paragraph:
            frames[parent].blocks.append(.paragraph(frame.inlines))
        case .heading(let level):
            frames[parent].blocks.append(.heading(level: level, content: frame.inlines))
        case .code(let language):
            frames[parent].blocks.append(.code(language: language, text: restoringMath(frame.text)))
        case .html:
            frames[parent].blocks.append(.html(frame.text))
        case .rule:
            frames[parent].blocks.append(.rule)
        case .table:
            frames[parent].blocks.append(.table(frame.table))
        case .tableHead, .tableBody:
            break
        case .row:
            if let tableIndex = frames.lastIndex(where: { if case .table = $0.kind { return true }; return false }) {
                let inHead: Bool
                if case .tableHead = frames[parent].kind { inHead = true } else { inHead = false }
                if inHead {
                    frames[tableIndex].table.header = frame.cells
                    frames[tableIndex].table.alignments = frame.aligns
                } else {
                    frames[tableIndex].table.rows.append(frame.cells)
                }
            }
        case .cell(let align):
            frames[parent].cells.append(frame.inlines)
            frames[parent].aligns.append(align)
        case .footnotes:
            frames[parent].blocks.append(.footnotes(frame.notes))
        case .footnote(let id, let label):
            frames[parent].notes.append(Footnote(id: id, label: label, blocks: frame.blocks))
        }
    }

    /// Text that arrives straight inside a list item (tight lists) or before a nested block
    /// becomes a paragraph of its own.
    func flushInlines(_ frame: inout Frame) {
        guard !frame.inlines.isEmpty else { return }
        switch frame.kind {
        case .paragraph, .heading, .cell:
            return
        default:
            frame.blocks.append(.paragraph(frame.inlines))
            frame.inlines = []
        }
    }

    // MARK: Spans

    func enterSpan(_ type: MD_SPANTYPE, _ detail: UnsafeMutableRawPointer?) {
        switch type {
        case MD_SPAN_EM:
            spans.append(Span(kind: .emphasis))
        case MD_SPAN_STRONG:
            spans.append(Span(kind: .strong))
        case MD_SPAN_DEL:
            spans.append(Span(kind: .strikethrough))
        case MD_SPAN_MARK:
            spans.append(Span(kind: .highlight))
        case MD_SPAN_A:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_A_DETAIL.self).pointee
            spans.append(Span(kind: .link(attribute(d.href), attribute(d.title))))
        case MD_SPAN_IMG:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_IMG_DETAIL.self).pointee
            spans.append(Span(kind: .image(attribute(d.src), attribute(d.title))))
        case MD_SPAN_CODE:
            spans.append(Span(kind: .code))
        case MD_SPAN_WIKILINK:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_WIKILINK_DETAIL.self).pointee
            spans.append(Span(kind: .wikiLink(attribute(d.target))))
        case MD_SPAN_FOOTNOTE_REF:
            let d = detail!.assumingMemoryBound(to: MD_SPAN_FOOTNOTE_REF_DETAIL.self).pointee
            append(.footnoteReference(id: Int(d.id), label: attribute(d.label)))
            spans.append(Span(kind: .plain))
        default:
            spans.append(Span(kind: .plain))
        }
    }

    func leaveSpan(_ type: MD_SPANTYPE) {
        if !spans.isEmpty { closeSpan() }
    }

    func closeSpan() {
        let span = spans.removeLast()
        let inline: Inline?
        switch span.kind {
        case .emphasis: inline = .emphasis(span.inlines)
        case .strong: inline = .strong(span.inlines)
        case .strikethrough: inline = .strikethrough(span.inlines)
        case .highlight: inline = .highlight(span.inlines)
        case .link(let href, let title): inline = .link(destination: href, title: title, content: span.inlines)
        case .wikiLink(let target): inline = .wikiLink(target: target, content: span.inlines)
        case .image(let src, let title): inline = .image(source: src, title: title, alt: span.inlines)
        case .code: inline = .code(restoringMath(span.code))
        case .plain:
            for item in span.inlines { append(item) }
            inline = nil
        }
        if let inline { append(inline) }
    }

    func append(_ inline: Inline) {
        if spans.isEmpty {
            frames[frames.count - 1].inlines.append(inline)
        } else {
            spans[spans.count - 1].inlines.append(inline)
        }
    }

    // MARK: Text

    func text(_ type: MD_TEXTTYPE, _ pointer: UnsafePointer<CChar>?, _ size: Int) {
        guard let pointer else { return }
        let string = pointer.withMemoryRebound(to: UInt8.self, capacity: size) {
            String(decoding: UnsafeBufferPointer(start: $0, count: size), as: UTF8.self)
        }
        let inCodeSpan: Bool
        if let last = spans.last, case .code = last.kind { inCodeSpan = true } else { inCodeSpan = false }

        switch type {
        case MD_TEXT_CODE:
            if inCodeSpan {
                spans[spans.count - 1].code += string
            } else {
                frames[frames.count - 1].text += string
            }
        case MD_TEXT_HTML:
            if case .html = frames[frames.count - 1].kind {
                frames[frames.count - 1].text += string
            } else {
                append(.html(string))
            }
        case MD_TEXT_BR:
            if inCodeSpan { spans[spans.count - 1].code += " " } else { append(.hardBreak) }
        case MD_TEXT_SOFTBR:
            if inCodeSpan { spans[spans.count - 1].code += " " } else { append(.softBreak) }
        case MD_TEXT_NULLCHAR:
            appendText("\u{FFFD}")
        case MD_TEXT_ENTITY:
            appendText(decodeEntity(string))
        default:
            if inCodeSpan {
                spans[spans.count - 1].code += string
            } else if case .code = frames[frames.count - 1].kind {
                frames[frames.count - 1].text += string
            } else {
                for piece in Placeholder.split(string) {
                    switch piece {
                    case .text(let t): appendText(t)
                    case .math(let index) where index < math.count: append(.math(index))
                    case .math: break
                    }
                }
            }
        }
    }

    /// Adjacent text runs are merged so the tree stays small.
    func appendText(_ text: String) {
        if spans.isEmpty {
            if case .text(let previous)? = frames[frames.count - 1].inlines.last {
                frames[frames.count - 1].inlines[frames[frames.count - 1].inlines.count - 1] = .text(previous + text)
                return
            }
        } else if case .text(let previous)? = spans[spans.count - 1].inlines.last {
            spans[spans.count - 1].inlines[spans[spans.count - 1].inlines.count - 1] = .text(previous + text)
            return
        }
        append(.text(text))
    }

    /// Formulas inside code are shown as they were written.
    func restoringMath(_ text: String) -> String {
        guard text.unicodeScalars.contains(Placeholder.open) else { return text }
        return Placeholder.split(text).map { piece in
            switch piece {
            case .text(let t): return t
            case .math(let index): return index < math.count ? math[index].source : ""
            }
        }.joined()
    }

    func attribute(_ a: MD_ATTRIBUTE) -> String {
        guard let text = a.text, a.size > 0 else { return "" }
        let size = Int(a.size)
        let full = text.withMemoryRebound(to: UInt8.self, capacity: size) {
            Array(UnsafeBufferPointer(start: $0, count: size))
        }
        guard let types = a.substr_types, let offsets = a.substr_offsets else {
            return String(decoding: full, as: UTF8.self)
        }
        var result = ""
        var k = 0
        while Int(offsets[k]) < size {
            let from = Int(offsets[k]), to = Int(offsets[k + 1])
            let piece = String(decoding: full[from..<to], as: UTF8.self)
            switch types[k] {
            case MD_TEXT_ENTITY: result += decodeEntity(piece)
            case MD_TEXT_NULLCHAR: result += "\u{FFFD}"
            default: result += piece
            }
            k += 1
        }
        return restoringMath(result)
    }
}

// MARK: - Display math

/// A display formula written inside a paragraph is lifted out into a block of its own,
/// with the text before and after it kept as separate paragraphs.
func liftingDisplayMath(_ blocks: [Block], math: [MathSpan]) -> [Block] {
    var out: [Block] = []
    for block in blocks {
        switch block {
        case .paragraph(let inlines):
            var current: [Inline] = []
            for inline in inlines {
                if case .math(let index) = inline, index < math.count, math[index].display {
                    let before = trimmingBreaks(current)
                    if !before.isEmpty { out.append(.paragraph(before)) }
                    out.append(.math(index))
                    current = []
                } else {
                    current.append(inline)
                }
            }
            let rest = trimmingBreaks(current)
            if !rest.isEmpty { out.append(.paragraph(rest)) }
        case .quote(let inner):
            out.append(.quote(liftingDisplayMath(inner, math: math)))
        case .alert(let kind, let inner):
            out.append(.alert(kind: kind, blocks: liftingDisplayMath(inner, math: math)))
        case .list(var list):
            list.items = list.items.map { ListItem(task: $0.task, blocks: liftingDisplayMath($0.blocks, math: math)) }
            out.append(.list(list))
        case .footnotes(let notes):
            out.append(.footnotes(notes.map { Footnote(id: $0.id, label: $0.label, blocks: liftingDisplayMath($0.blocks, math: math)) }))
        default:
            out.append(block)
        }
    }
    return out
}

private func trimmingBreaks(_ inlines: [Inline]) -> [Inline] {
    var result = inlines[...]
    func isBreak(_ i: Inline) -> Bool {
        switch i {
        case .softBreak, .hardBreak: return true
        case .text(let t): return t.allSatisfy { $0 == " " || $0 == "\t" }
        default: return false
        }
    }
    while let first = result.first, isBreak(first) { result = result.dropFirst() }
    while let last = result.last, isBreak(last) { result = result.dropLast() }
    return Array(result)
}

// MARK: - Plain text and anchors

/// The text of some inlines without formatting, with formulas as their LaTeX.
public func plainText(_ inlines: [Inline], math: [MathSpan]) -> String {
    var out = ""
    for inline in inlines {
        switch inline {
        case .text(let t), .code(let t): out += t
        case .math(let index): out += index < math.count ? math[index].tex : ""
        case .softBreak, .hardBreak: out += " "
        case .emphasis(let c), .strong(let c), .strikethrough(let c), .highlight(let c):
            out += plainText(c, math: math)
        case .link(_, _, let c), .wikiLink(_, let c), .image(_, _, let c):
            out += plainText(c, math: math)
        case .footnoteReference, .html: break
        }
    }
    return out
}

/// GitHub's heading anchors: lowercase, spaces become hyphens, punctuation is dropped.
public func anchorSlug(_ text: String) -> String {
    var out = ""
    for scalar in text.lowercased().unicodeScalars {
        if scalar == " " {
            out += "-"
        } else if scalar == "-" || scalar == "_" || scalar.properties.isAlphabetic
                    || scalar.properties.numericType != nil || scalar.properties.generalCategory == .nonspacingMark {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
