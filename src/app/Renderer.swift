// Turns a parsed document into styled text for the reader.

import AppKit

struct OutlineEntry: Equatable {
    let level: Int
    let title: String
    let anchor: String
    /// Where the heading starts in the rendered text.
    let location: Int
}

@MainActor
final class Renderer {
    private let theme: Theme
    private let document: Document
    private let baseURL: URL?
    private let boxes: MathBoxCache
    private var normalizer: TeXNormalizer
    private let out = NSMutableAttributedString()
    private(set) var outline: [OutlineEntry] = []
    private var anchorCounts: [String: Int] = [:]
    private var fonts: [String: NSFont] = [:]
    private var referencedFootnotes: Set<Int> = []
    /// Paragraphs with the same layout share one style object, and repeated formulas share one
    /// attachment; a long document has thousands of both.
    private var styles: [String: NSParagraphStyle] = [:]
    private var attachments: [String: MathAttachment] = [:]

    init(document: Document, theme: Theme, baseURL: URL?, boxes: MathBoxCache) {
        self.document = document
        self.theme = theme
        self.baseURL = baseURL
        self.boxes = boxes
        normalizer = TeXNormalizer(symbolCommands: MathEngine.shared.symbolCommands,
                                   commandSymbols: MathEngine.shared.commandSymbols)
    }

    func render() -> NSAttributedString {
        out.beginEditing()
        for block in document.blocks {
            autoreleasepool { renderBlocks([block], Context()) }
        }
        // The last block's paragraph break would add an empty line at the end.
        if out.length > 0 && out.mutableString.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        out.endEditing()
        return out
    }

    // MARK: - Context

    enum Marker {
        case text(String)
        case checkbox(Bool)
    }

    struct Context {
        /// Left edge of the content, relative to the innermost block.
        var indent: CGFloat = 0
        /// Where a list marker's gutter starts.
        var markerIndent: CGFloat = 0
        /// Enclosing quotes, alerts, code blocks and table cells.
        var blocks: [NSTextBlock] = []
        var color: NSColor = Theme.text
        var listDepth = 0
        var tight = false
        /// A list marker waiting for the item's first paragraph.
        var marker: Marker?
        /// Text scale, for footnotes.
        var scale: CGFloat = 1
    }

    struct Style {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        var italic = false
        var monospaced = false
        var color: NSColor
        var strike = false
        var underline = false
        var highlight = false
        var code = false
        var link: Any?
        var toolTip: String?
        var baseline: CGFloat = 0
    }

    private func bodyStyle(_ ctx: Context) -> Style {
        Style(size: theme.size * ctx.scale, color: ctx.color)
    }

    private func font(_ s: Style) -> NSFont {
        let size = s.monospaced ? (s.size * 0.9).rounded() : s.size
        let key = "\(size)|\(s.weight.rawValue)|\(s.italic)|\(s.monospaced)"
        if let f = fonts[key] { return f }
        let f = theme.font(size: size, weight: s.weight, italic: s.italic, monospaced: s.monospaced)
        fonts[key] = f
        return f
    }

    private func attributes(_ s: Style) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(s), .foregroundColor: s.color]
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.code { a[.markyCode] = true }
        if s.highlight { a[.markyHighlight] = true }
        if let link = s.link { a[.link] = link }
        if let tip = s.toolTip, !tip.isEmpty { a[.toolTip] = tip }
        if s.baseline != 0 { a[.baselineOffset] = s.baseline }
        return a
    }

    // MARK: - Blocks

    private func renderBlocks(_ blocks: [Block], _ context: Context) {
        for (index, block) in blocks.enumerated() {
            var ctx = context
            if index > 0 { ctx.marker = nil }
            if ctx.marker != nil {
                switch block {
                case .paragraph, .heading, .math:
                    break
                default:
                    // An item that starts with something other than text gets its marker on a line of its own.
                    emitParagraph(NSAttributedString(), ctx)
                    ctx.marker = nil
                }
            }
            switch block {
            case .paragraph(let content):
                emitParagraph(inlines(content, bodyStyle(ctx)), ctx)
            case .heading(let level, let content):
                renderHeading(level, content, ctx)
            case .quote(let inner):
                var c = enterBlock(BackgroundBlock(kind: .quote, theme: theme, indent: ctx.indent), ctx)
                c.color = Theme.secondaryText
                renderBlocks(inner, c)
                setLastParagraphSpacing(0)
            case .alert(let kind, let inner):
                renderAlert(kind, inner, ctx)
            case .list(let list):
                renderList(list, ctx)
            case .code(let language, let text):
                renderCode(text, label: language, ctx)
            case .html(let html):
                renderHTMLBlock(html, ctx)
            case .rule:
                let rule = NSTextAttachment()
                rule.attachmentCell = RuleCell()
                emitParagraph(NSAttributedString(attachment: rule), ctx, before: theme.size * 0.4,
                              after: theme.size * 1.2, lineHeight: 1)
            case .table(let table):
                renderTable(table, ctx)
            case .math(let index):
                let content = math(index, inline: false, bodyStyle(ctx))
                emitParagraph(content, ctx, before: (theme.size * 0.35).rounded(), after: (theme.paragraphSpacing * 1.25).rounded(),
                              alignment: .center, lineHeight: 1)
            case .frontMatter(let text):
                renderCode(text, label: "YAML", ctx, muted: true)
            case .footnotes(let notes):
                renderFootnotes(notes, ctx)
            }
        }
    }

    private func enterBlock(_ block: NSTextBlock, _ ctx: Context) -> Context {
        var c = ctx
        c.blocks.append(block)
        c.indent = 0
        c.markerIndent = 0
        c.marker = nil
        return c
    }

    /// Appends one paragraph, with a list marker in front of it if one is pending.
    private func emitParagraph(_ content: NSAttributedString, _ ctx: Context, before: CGFloat = 0,
                               after: CGFloat? = nil, alignment: NSTextAlignment = .natural,
                               lineHeight: CGFloat? = nil, anchor: String? = nil) {
        let start = out.length
        let spacingAfter = after ?? (ctx.tight ? (theme.size * 0.3).rounded() : theme.paragraphSpacing * ctx.scale)
        let gap = (theme.size * 0.45).rounded()
        let style = paragraphStyle(lineHeight: lineHeight ?? theme.lineHeightMultiple, before: before, after: spacingAfter,
                                   alignment: alignment, blocks: ctx.blocks, indent: ctx.indent,
                                   firstLine: ctx.marker == nil ? ctx.indent : ctx.markerIndent,
                                   markerTab: ctx.marker == nil ? nil : ctx.indent - gap)
        let bodyAttributes = attributes(bodyStyle(ctx))
        if let marker = ctx.marker {
            // "\t<marker>\t<text>": the marker is right-aligned in the gutter before the text.
            out.append(NSAttributedString(string: "\t", attributes: bodyAttributes))
            switch marker {
            case .text(let text):
                var s = bodyStyle(ctx)
                s.color = Theme.secondaryText
                if !text.hasSuffix(".") { s.weight = .bold }
                out.append(NSAttributedString(string: text, attributes: attributes(s)))
            case .checkbox(let checked):
                let box = NSTextAttachment()
                box.attachmentCell = CheckboxCell(checked: checked, size: theme.size * ctx.scale)
                let s = NSMutableAttributedString(attachment: box)
                s.addAttributes(bodyAttributes, range: NSRange(location: 0, length: s.length))
                out.append(s)
            }
            out.append(NSAttributedString(string: "\t", attributes: bodyAttributes))
        }
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.paragraphStyle, value: style, range: range)
        if let anchor { out.addAttribute(.markyAnchor, value: anchor, range: range) }
    }

    private func paragraphStyle(lineHeight: CGFloat, before: CGFloat, after: CGFloat, alignment: NSTextAlignment,
                                blocks: [NSTextBlock], indent: CGFloat, firstLine: CGFloat, markerTab: CGFloat?,
                                tabInterval: CGFloat? = nil) -> NSParagraphStyle {
        let blockIDs = blocks.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) }.joined(separator: ",")
        let key = "\(lineHeight)|\(before)|\(after)|\(alignment.rawValue)|\(indent)|\(firstLine)|\(markerTab ?? -1)|\(tabInterval ?? -1)|\(blockIDs)"
        if let style = styles[key] { return style }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.alignment = alignment
        style.textBlocks = blocks
        style.headIndent = indent
        style.firstLineHeadIndent = firstLine
        style.defaultTabInterval = tabInterval ?? theme.size * 2
        style.tabStops = markerTab.map { [NSTextTab(textAlignment: .right, location: $0), NSTextTab(textAlignment: .left, location: indent)] } ?? []
        styles[key] = style
        return style
    }

    private func setLastParagraphSpacing(_ value: CGFloat) {
        guard out.length > 0 else { return }
        let text = out.mutableString
        let range = text.paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let style = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              style.paragraphSpacing != value else { return }
        out.addAttribute(.paragraphStyle, value: restyled(style, after: value), range: range)
    }

    /// A copy of a style with a different spacing after it or tab interval, from the shared set.
    private func restyled(_ p: NSParagraphStyle, after: CGFloat? = nil, tabInterval: CGFloat? = nil) -> NSParagraphStyle {
        let markerTab = p.tabStops.count == 2 ? p.tabStops[0].location : nil
        return paragraphStyle(lineHeight: p.lineHeightMultiple, before: p.paragraphSpacingBefore, after: after ?? p.paragraphSpacing,
                              alignment: p.alignment, blocks: p.textBlocks, indent: p.headIndent,
                              firstLine: p.firstLineHeadIndent, markerTab: markerTab,
                              tabInterval: tabInterval ?? (p.defaultTabInterval == theme.size * 2 ? nil : p.defaultTabInterval))
    }

    private func renderHeading(_ level: Int, _ content: [Inline], _ ctx: Context) {
        var style = bodyStyle(ctx)
        let size = theme.headingSize(level) * ctx.scale
        style.size = size
        style.weight = theme.headingWeight(level)
        if level == 6 { style.color = Theme.secondaryText }
        let title = plainText(content, math: document.math)
        let anchor = uniqueAnchor(anchorSlug(title))
        let before: CGFloat = out.length == 0 ? 0 : (level <= 2 ? size * 1.0 : size * 0.85)
        let location = out.length
        emitParagraph(inlines(content, style), ctx, before: before.rounded(), after: (size * 0.42).rounded(),
                      lineHeight: 1.08, anchor: anchor)
        outline.append(OutlineEntry(level: level, title: title.trimmingSpaces(), anchor: anchor, location: location))
    }

    private func uniqueAnchor(_ slug: String) -> String {
        let count = anchorCounts[slug, default: 0]
        anchorCounts[slug] = count + 1
        return count == 0 ? slug : "\(slug)-\(count)"
    }

    private func renderAlert(_ kind: String, _ inner: [Block], _ ctx: Context) {
        let color = Theme.alertColor(kind)
        let c = enterBlock(BackgroundBlock(kind: .alert(color), theme: theme, indent: ctx.indent), ctx)
        let title = NSMutableAttributedString()
        if let cell = SymbolCell(name: Theme.alertSymbol(kind), color: color, pointSize: theme.size * 0.95,
                                 label: Theme.alertTitle(kind)) {
            let icon = NSTextAttachment()
            icon.attachmentCell = cell
            title.append(NSAttributedString(attachment: icon))
            title.append(NSAttributedString(string: "  "))
        }
        var style = bodyStyle(c)
        style.weight = .semibold
        style.color = color
        title.append(NSAttributedString(string: Theme.alertTitle(kind), attributes: attributes(style)))
        title.addAttributes([.font: font(style)], range: NSRange(location: 0, length: title.length))
        emitParagraph(title, c, after: (theme.size * 0.35).rounded())
        renderBlocks(inner, c)
        setLastParagraphSpacing((theme.size * 0.45).rounded())
    }

    private func renderList(_ list: List, _ ctx: Context) {
        let bullets = ["•", "◦", "▪"]
        for (i, item) in list.items.enumerated() {
            var c = ctx
            c.markerIndent = ctx.indent
            c.indent = ctx.indent + theme.listIndent
            c.listDepth = ctx.listDepth + 1
            c.tight = list.tight
            if let task = item.task {
                c.marker = .checkbox(task)
            } else if list.ordered {
                c.marker = .text("\(list.start + i).")
            } else {
                c.marker = .text(bullets[ctx.listDepth % bullets.count])
            }
            if item.blocks.isEmpty {
                emitParagraph(NSAttributedString(), c)
            } else {
                renderBlocks(item.blocks, c)
            }
        }
        if ctx.listDepth == 0 || !ctx.tight { setLastParagraphSpacing(theme.paragraphSpacing * ctx.scale) }
    }

    private func renderCode(_ text: String, label: String, _ ctx: Context, muted: Bool = false) {
        let c = enterBlock(BackgroundBlock(kind: .code(label: label), theme: theme, indent: ctx.indent), ctx)
        var style = bodyStyle(c)
        style.monospaced = true
        style.size = theme.size * ctx.scale
        if muted { style.color = Theme.secondaryText }
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let attrs = attributes(style)
        let codeStart = out.length
        for line in lines {
            emitParagraph(NSAttributedString(string: String(line), attributes: attrs), c, after: 0, lineHeight: 1.12)
        }
        // Tabs in code are four spaces wide.
        let tab = ("    " as NSString).size(withAttributes: [.font: font(style)]).width
        let codeRange = NSRange(location: codeStart, length: out.length - codeStart)
        var runs: [(NSRange, NSParagraphStyle)] = []
        out.enumerateAttribute(.paragraphStyle, in: codeRange) { value, range, _ in
            if let p = value as? NSParagraphStyle { runs.append((range, p)) }
        }
        for (range, p) in runs { out.addAttribute(.paragraphStyle, value: restyled(p, tabInterval: tab), range: range) }
    }

    private func renderTable(_ table: Table, _ ctx: Context) {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setWidth(ctx.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        textTable.setWidth(theme.paragraphSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        let rows = (table.header.isEmpty ? [] : [table.header]) + table.rows
        for (r, row) in rows.enumerated() {
            let isHeader = r == 0 && !table.header.isEmpty
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: column, columnSpan: 1)
                let vertical = (theme.size * 0.42).rounded(), horizontal = (theme.size * 0.75).rounded()
                cell.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(horizontal, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(horizontal, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(isHeader ? 1.5 : 1, type: .absoluteValueType, for: .border, edge: .maxY)
                cell.setBorderColor(Theme.rule, for: .maxY)
                // A short cell sits level with the middle of a tall one, such as a fraction.
                cell.verticalAlignment = .middleAlignment
                if r == rows.count - 1 {
                    cell.setWidth(theme.paragraphSpacing * 1.25, type: .absoluteValueType, for: .margin, edge: .maxY)
                }
                if isHeader { cell.backgroundColor = Theme.tableHeaderBackground }
                var c = ctx
                c.blocks.append(cell)
                c.indent = 0
                c.markerIndent = 0
                c.marker = nil
                var style = bodyStyle(c)
                if isHeader { style.weight = .semibold }
                let content = column < row.count ? inlines(row[column], style) : NSAttributedString()
                let alignment: NSTextAlignment
                switch column < table.alignments.count ? table.alignments[column] : .none {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .natural
                }
                emitParagraph(content, c, after: 0, alignment: alignment, lineHeight: 1.12)
            }
        }
    }

    private func renderFootnotes(_ notes: [Footnote], _ ctx: Context) {
        let rule = NSTextAttachment()
        rule.attachmentCell = RuleCell()
        emitParagraph(NSAttributedString(attachment: rule), ctx, before: theme.size, after: theme.size * 0.6, lineHeight: 1)
        for note in notes {
            var c = ctx
            c.scale = 0.88
            c.color = Theme.secondaryText
            c.markerIndent = ctx.indent
            c.indent = ctx.indent + theme.listIndent
            c.marker = .text("\(note.id).")
            c.tight = true
            let start = out.length
            renderBlocks(note.blocks.isEmpty ? [.paragraph([])] : note.blocks, c)
            out.addAttribute(.markyAnchor, value: "fn-\(note.id)", range: NSRange(location: start, length: max(0, out.length - start)))
            // A link back to where the note was referenced, before the last paragraph break.
            if out.length > start {
                var back = bodyStyle(c)
                back.link = "#fnref-\(note.id)"
                back.color = Theme.link
                let insertAt = out.mutableString.hasSuffix("\n") ? out.length - 1 : out.length
                let paragraph = out.attribute(.paragraphStyle, at: max(start, insertAt - 1), effectiveRange: nil)
                var a = attributes(back)
                a[.paragraphStyle] = paragraph
                out.insert(NSAttributedString(string: " ↩", attributes: a), at: insertAt)
            }
        }
    }

    // MARK: - Inlines

    private func inlines(_ items: [Inline], _ base: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var style = base
        var htmlStack: [(String, Style)] = []
        for item in items {
            switch item {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attributes(style)))
            case .code(let text):
                var s = style
                s.monospaced = true
                s.code = true
                result.append(NSAttributedString(string: text, attributes: attributes(s)))
            case .math(let index):
                result.append(math(index, inline: true, style))
            case .softBreak:
                result.append(NSAttributedString(string: " ", attributes: attributes(style)))
            case .hardBreak:
                result.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
            case .emphasis(let content):
                var s = style
                s.italic = true
                result.append(inlines(content, s))
            case .strong(let content):
                var s = style
                s.weight = style.weight == .regular ? .semibold : .bold
                result.append(inlines(content, s))
            case .strikethrough(let content):
                var s = style
                s.strike = true
                result.append(inlines(content, s))
            case .highlight(let content):
                var s = style
                s.highlight = true
                result.append(inlines(content, s))
            case .link(let destination, let title, let content):
                var s = style
                s.link = linkTarget(destination)
                s.color = Theme.link
                s.toolTip = title.isEmpty ? destination : title
                result.append(inlines(content, s))
            case .wikiLink(let target, let content):
                // [[Page]], [[Page#Heading]] or, within the same note, [[#Heading]].
                var s = style
                let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let page = String(parts[0]).trimmingSpaces()
                let heading = parts.count > 1 ? anchorSlug(String(parts[1]).trimmingSpaces()) : ""
                if page.isEmpty {
                    s.link = heading.isEmpty ? nil : "#" + heading
                } else {
                    s.link = fileLink(page.hasSuffix(".md") ? page : page + ".md", fragment: heading.isEmpty ? nil : heading)
                }
                s.color = Theme.link
                result.append(inlines(content, s))
            case .image(let source, let title, let alt):
                result.append(image(source, alt: plainText(alt, math: document.math), title: title, style))
            case .footnoteReference(let id, _):
                var s = style
                s.size = style.size * 0.75
                s.baseline = style.size * 0.38
                s.link = "#fn-\(id)"
                s.color = Theme.link
                var a = attributes(s)
                if !referencedFootnotes.contains(id) {
                    referencedFootnotes.insert(id)
                    a[.markyAnchor] = "fnref-\(id)"
                }
                result.append(NSAttributedString(string: "\(id)", attributes: a))
            case .html(let raw):
                if let tag = Renderer.parseTag(raw) {
                    applyInlineHTML(tag, style: &style, stack: &htmlStack, base: base, into: result)
                }
            }
        }
        return result
    }

    private func math(_ index: Int, inline: Bool, _ style: Style) -> NSAttributedString {
        guard index < document.math.count else { return NSAttributedString() }
        let span = document.math[index]
        let tex = normalizer.normalize(span.tex, display: span.display)
        let size = (theme.mathSize * style.size / theme.size).rounded()
        let key = "\(span.display)|\(size)|\(span.source)|\(tex)"
        let attachment: MathAttachment
        if let shared = attachments[key] {
            attachment = shared
        } else {
            attachment = MathAttachment(source: span.source, cell: MathCell(tex: tex, display: span.display, size: size, boxes: boxes))
            attachments[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        var a = attributes(style)
        a[.toolTip] = nil
        result.addAttributes(a, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Relative links resolve against the document's folder; #anchors stay as they are.
    private func linkTarget(_ destination: String) -> Any {
        if destination.hasPrefix("#") { return destination }
        if let url = URL(string: destination, relativeTo: baseURL), url.scheme != nil { return url.absoluteURL }
        // A path URLs can't hold as written, e.g. with spaces: split off the #fragment first.
        guard let hash = destination.firstIndex(of: "#") else { return fileLink(destination, fragment: nil) ?? destination }
        let fragment = String(destination[destination.index(after: hash)...])
        return fileLink(String(destination[..<hash]), fragment: fragment.isEmpty ? nil : fragment) ?? destination
    }

    /// A file path, relative to the document's folder, with an optional #fragment.
    private func fileLink(_ path: String, fragment: String?) -> URL? {
        guard let baseURL else { return nil }
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: baseURL).absoluteURL
        guard let fragment, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = fragment
        return parts.url ?? url
    }

    private func image(_ source: String, alt: String, title: String, _ style: Style) -> NSAttributedString {
        if let picture = loadImage(source) {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ImageCell(picture: picture)
            let s = NSMutableAttributedString(attachment: attachment)
            var a = attributes(style)
            a[.toolTip] = title.isEmpty ? (alt.isEmpty ? nil : alt) : title
            s.addAttributes(a.compactMapValues { $0 }, range: NSRange(location: 0, length: s.length))
            return s
        }
        // Remote images are not fetched: Marky never goes online. Show the description as a link.
        var s = style
        s.color = Theme.secondaryText
        s.italic = true
        if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
            s.link = url
            s.color = Theme.link
        }
        s.toolTip = source
        return NSAttributedString(string: "[" + (alt.isEmpty ? "image" : alt) + "]", attributes: attributes(s))
    }

    private func loadImage(_ source: String) -> NSImage? {
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
            else { return nil }
            return NSImage(data: data)
        }
        guard let target = linkTarget(source) as? URL, target.isFileURL else { return nil }
        return NSImage(contentsOf: target)
    }

    // MARK: - HTML

    struct Tag {
        var name: String
        var closing: Bool
        var attributes: [String: String]
    }

    static func parseTag(_ raw: String) -> Tag? {
        var s = Substring(raw)
        guard s.hasPrefix("<"), s.hasSuffix(">"), !s.hasPrefix("<!") else { return nil }
        s = s.dropFirst().dropLast()
        if s.hasSuffix("/") { s = s.dropLast() }
        let closing = s.hasPrefix("/")
        if closing { s = s.dropFirst() }
        let name = s.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        var rest = s.dropFirst(name.count)
        while true {
            rest = rest.drop { $0.isWhitespace }
            let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
            guard !key.isEmpty else { break }
            rest = rest.dropFirst(key.count).drop { $0.isWhitespace }
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop { $0.isWhitespace }
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    rest = rest.dropFirst()
                    value = String(rest.prefix { $0 != quote })
                    rest = rest.dropFirst(value.count + 1)
                } else {
                    value = String(rest.prefix { !$0.isWhitespace })
                    rest = rest.dropFirst(value.count)
                }
            }
            attributes[key.lowercased()] = decodeEntities(value)
        }
        return Tag(name: name, closing: closing, attributes: attributes)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.prefix(32).firstIndex(of: ";") {
                out += decodeEntity(String(tail[...semi]))
                rest = tail[tail.index(after: semi)...]
            } else {
                out += "&"
                rest = tail.dropFirst()
            }
        }
        return out + rest
    }

    /// Applies an inline HTML tag to the text that follows it.
    private func applyInlineHTML(_ tag: Tag, style: inout Style, stack: inout [(String, Style)], base: Style,
                                 into result: NSMutableAttributedString) {
        if tag.closing {
            if let index = stack.lastIndex(where: { $0.0 == tag.name }) {
                style = stack[index].1
                stack.removeSubrange(index...)
            }
            return
        }
        switch tag.name {
        case "br":
            result.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
            return
        case "img":
            result.append(image(tag.attributes["src"] ?? "", alt: tag.attributes["alt"] ?? "", title: tag.attributes["title"] ?? "", style))
            return
        default:
            break
        }
        stack.append((tag.name, style))
        switch tag.name {
        case "b", "strong": style.weight = .semibold
        case "i", "em", "cite", "var", "dfn": style.italic = true
        case "u", "ins": style.underline = true
        case "s", "del", "strike": style.strike = true
        case "code", "tt", "kbd", "samp": style.monospaced = true; style.code = true
        case "mark": style.highlight = true
        case "small": style.size = base.size * 0.85
        case "sup": style.baseline = base.size * 0.38; style.size = base.size * 0.75
        case "sub": style.baseline = -base.size * 0.18; style.size = base.size * 0.75
        case "a":
            if let href = tag.attributes["href"] {
                style.link = linkTarget(href)
                style.color = Theme.link
            }
        default: break
        }
    }

    /// Raw HTML blocks get a simple reading: text and inline formatting are kept, block tags start
    /// new lines, images are shown, and everything else (scripts, styles, comments) is dropped.
    private func renderHTMLBlock(_ html: String, _ ctx: Context) {
        var paragraph = NSMutableAttributedString()
        var style = bodyStyle(ctx)
        var stack: [(String, Style)] = []
        var alignment: NSTextAlignment = .natural
        var preformatted = false
        var skipping: String?

        func flush() {
            let trimmed = paragraph.mutableString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || paragraph.containsAttachments(in: NSRange(location: 0, length: paragraph.length)) {
                emitParagraph(paragraph, ctx, alignment: alignment)
            }
            paragraph = NSMutableAttributedString()
        }

        var rest = Substring(html)
        while !rest.isEmpty {
            if rest.hasPrefix("<!--") {
                if let end = rest.range(of: "-->") { rest = rest[end.upperBound...] } else { rest = "" }
                continue
            }
            if rest.first == "<", let close = rest.firstIndex(of: ">"), let tag = Renderer.parseTag(String(rest[...close])) {
                rest = rest[rest.index(after: close)...]
                if let skip = skipping {
                    if tag.closing && tag.name == skip { skipping = nil }
                    continue
                }
                switch tag.name {
                case "script", "style", "head", "title":
                    if !tag.closing { skipping = tag.name }
                case "p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "table", "ul", "ol",
                     "blockquote", "details", "section", "article", "header", "footer", "figure", "figcaption", "dl", "dt", "dd":
                    flush()
                    if tag.closing {
                        if let i = stack.lastIndex(where: { $0.0 == tag.name }) { style = stack[i].1; stack.removeSubrange(i...) }
                        alignment = .natural
                    } else {
                        stack.append((tag.name, style))
                        if let align = tag.attributes["align"]?.lowercased() {
                            alignment = align == "center" ? .center : align == "right" ? .right : .natural
                        }
                        if tag.name == "center" { alignment = .center }
                        if tag.name.count == 2, tag.name.hasPrefix("h"), let level = Int(tag.name.dropFirst()) {
                            style.size = theme.headingSize(level)
                            style.weight = theme.headingWeight(level)
                        }
                        if tag.name == "li" { paragraph.append(NSAttributedString(string: "•  ", attributes: attributes(style))) }
                    }
                case "summary":
                    flush()
                    if tag.closing {
                        if let i = stack.lastIndex(where: { $0.0 == "summary" }) { style = stack[i].1; stack.removeSubrange(i...) }
                    } else {
                        stack.append(("summary", style))
                        style.weight = .semibold
                    }
                case "pre":
                    flush()
                    preformatted = !tag.closing
                    if tag.closing {
                        if let i = stack.lastIndex(where: { $0.0 == "pre" }) { style = stack[i].1; stack.removeSubrange(i...) }
                    } else {
                        stack.append(("pre", style))
                        style.monospaced = true
                    }
                case "hr":
                    flush()
                    renderBlocks([.rule], ctx)
                case "td", "th":
                    if !tag.closing && paragraph.length > 0 {
                        paragraph.append(NSAttributedString(string: "   ", attributes: attributes(style)))
                    }
                    if tag.name == "th" {
                        if tag.closing {
                            if let i = stack.lastIndex(where: { $0.0 == "th" }) { style = stack[i].1; stack.removeSubrange(i...) }
                        } else {
                            stack.append(("th", style))
                            style.weight = .semibold
                        }
                    }
                default:
                    applyInlineHTML(tag, style: &style, stack: &stack, base: bodyStyle(ctx), into: paragraph)
                }
                continue
            }
            // Text up to the next tag.
            let end = rest.dropFirst().firstIndex(of: "<") ?? rest.endIndex
            let chunk = String(rest[..<end])
            rest = rest[end...]
            if skipping != nil { continue }
            var text = Renderer.decodeEntities(chunk)
            if !preformatted {
                text = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
                    .appending(chunk.last.map { $0 == " " || $0 == "\n" } == true ? " " : "")
                if chunk.first == " " || chunk.first == "\n", paragraph.length > 0 { text = " " + text }
            }
            for piece in Placeholder.split(text) {
                switch piece {
                case .text(let t): paragraph.append(NSAttributedString(string: t, attributes: attributes(style)))
                case .math(let index): paragraph.append(math(index, inline: true, style))
                }
            }
        }
        flush()
    }
}
