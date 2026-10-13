// Finds the formulas in a Markdown file before the Markdown parser sees it.
//
// Markdown and LaTeX disagree about backslashes, underscores and asterisks, so every formula is
// swapped for a placeholder (U+E000, its index, U+E001) that Markdown passes through untouched.
// Recognised delimiters: $…$, $$…$$, \(…\), \[…\], \begin{env}…\end{env}, $`…`$ and ```math
// fences. Code spans, code blocks, HTML comments, autolinks and link targets are left alone.

/// A formula found in the source.
public struct MathSpan: Equatable, Sendable {
    /// The LaTeX between the delimiters.
    public var tex: String
    /// Display math gets its own centred line; inline math sits in the text.
    public var display: Bool
    /// The formula as written, delimiters included, for copying.
    public var source: String

    public init(tex: String, display: Bool, source: String) {
        self.tex = tex
        self.display = display
        self.source = source
    }
}

/// The Markdown with its formulas replaced by placeholders.
public struct ScanResult: Sendable {
    public var markdown: String
    public var math: [MathSpan]
    /// YAML front matter at the very top of the file, without its --- fences.
    public var frontMatter: String?
}

public enum Placeholder {
    public static let open: Unicode.Scalar = "\u{E000}"
    public static let close: Unicode.Scalar = "\u{E001}"
    static let openBytes: [UInt8] = [0xEE, 0x80, 0x80]
    static let closeBytes: [UInt8] = [0xEE, 0x80, 0x81]

    /// Splits text into plain runs and formula indexes.
    public static func split(_ text: String) -> [Piece] {
        guard text.unicodeScalars.contains(open) else { return [.text(text)] }
        var pieces: [Piece] = []
        var plain = String.UnicodeScalarView()
        var pending = String.UnicodeScalarView()  // an open marker and digits not yet closed
        var number = 0
        for scalar in text.unicodeScalars {
            if scalar == open {
                plain.append(contentsOf: pending)
                pending = .init()
                pending.append(scalar)
                number = 0
            } else if !pending.isEmpty {
                if scalar == close, pending.count > 1 {
                    if !plain.isEmpty { pieces.append(.text(String(plain))); plain = .init() }
                    pieces.append(.math(number))
                    pending = .init()
                } else if scalar.value >= 48 && scalar.value <= 57 && pending.count < 9 {
                    pending.append(scalar)
                    number = number * 10 + Int(scalar.value - 48)
                } else {
                    plain.append(contentsOf: pending)
                    plain.append(scalar)
                    pending = .init()
                }
            } else {
                plain.append(scalar)
            }
        }
        plain.append(contentsOf: pending)
        if !plain.isEmpty { pieces.append(.text(String(plain))) }
        return pieces
    }

    public enum Piece: Equatable {
        case text(String)
        case math(Int)
    }
}

/// Environments that start display math even without $$ around them.
let mathEnvironments: Set<String> = [
    "equation", "equation*", "align", "align*", "alignat", "alignat*", "gather", "gather*",
    "multline", "multline*", "flalign", "flalign*", "eqnarray", "eqnarray*", "displaymath", "math",
    "aligned", "alignedat", "gathered", "split", "cases", "dcases", "rcases", "array", "subarray",
    "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "CD",
]

public func scan(_ text: String) -> ScanResult {
    var scanner = MathScanner(normalizingNewlines(text))
    return scanner.run()
}

private func normalizingNewlines(_ text: String) -> [UInt8] {
    var bytes = Array(text.utf8)
    guard bytes.contains(13) else { return bytes }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 13 {
            out.append(10)
            if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 1 }
        } else {
            out.append(b)
        }
        i += 1
    }
    bytes = out
    return bytes
}

private let newline = UInt8(ascii: "\n")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let backslash = UInt8(ascii: "\\")
private let dollar = UInt8(ascii: "$")
private let backtick = UInt8(ascii: "`")
private let tilde = UInt8(ascii: "~")

private struct Fence {
    var char: UInt8
    var length: Int
    var math: Bool
    var start: Int            // first byte of the opening fence line, for the formula's source
    var prefix: [UInt8] = []  // quote markers and indentation of the opening line
    var content: [UInt8] = []
}

private struct MathScanner {
    let s: [UInt8]
    let n: Int
    var out: [UInt8] = []
    var math: [MathSpan] = []
    var frontMatter: String?
    var quoteDepth = 0  // block quote markers on the current line
    var lineContentStart = 0  // where the current line's content starts, after its prefix
    /// Where the last failed search stopped (a blank line, a new block or the end of the file).
    var lastStop = 0
    /// Searches known to fail, by closer: no closer exists from `from` up to `to`. A later search
    /// that starts inside such a range fails at once, which keeps text with thousands of unmatched
    /// $ signs or backticks linear rather than quadratic.
    var deadEnds: [[UInt8]: (from: Int, to: Int)] = [:]
    /// Where each \begin{env} met so far closes, and the ones that never do.
    var environmentEnds: [Int: Int] = [:]
    var environmentsUnclosed: Set<Int> = []

    init(_ bytes: [UInt8]) {
        s = bytes
        n = bytes.count
        out.reserveCapacity(n + 256)
    }

    mutating func run() -> ScanResult {
        var i = skipFrontMatter()
        var atLineStart = true
        var previousBlank = true      // the line before this one was blank (or there was none)
        var inIndentedCode = false
        var inList = false            // a list started and no unindented paragraph has ended it
        var fence: Fence?

        while i < n {
            if atLineStart {
                atLineStart = false
                let end = lineEnd(i)
                let (prefixEnd, indent) = containerPrefix(i, end)
                let blank = prefixEnd == end || isBlank(prefixEnd, end)
                quoteDepth = s[i..<prefixEnd].reduce(0) { $1 == UInt8(ascii: ">") ? $0 + 1 : $0 }
                lineContentStart = prefixEnd

                if var f = fence {
                    if isClosingFence(prefixEnd, end, f) {
                        if f.math {
                            // The formula takes the place of the whole fence, inside the same container.
                            out.append(contentsOf: f.prefix)
                            emit(tex: String(decoding: f.content, as: UTF8.self), display: true,
                                 source: String(decoding: s[f.start..<end], as: UTF8.self))
                        } else {
                            out.append(contentsOf: s[i..<end])
                        }
                        fence = nil
                        i = copyNewline(end)
                    } else if f.math {
                        if !f.content.isEmpty { f.content.append(newline) }
                        f.content.append(contentsOf: s[prefixEnd..<end])
                        fence = f
                        i = end < n ? end + 1 : end
                    } else {
                        out.append(contentsOf: s[i..<end])
                        i = copyNewline(end)
                    }
                    atLineStart = true
                    continue
                }

                if blank {
                    out.append(contentsOf: s[i..<end])
                    i = copyNewline(end)
                    atLineStart = true
                    previousBlank = true
                    continue
                }

                if inIndentedCode && indent >= 4 || (previousBlank && indent >= 4 && !inList) {
                    inIndentedCode = true
                    out.append(contentsOf: s[i..<end])
                    i = copyNewline(end)
                    atLineStart = true
                    previousBlank = false
                    continue
                }
                inIndentedCode = false

                // Inside a list a fence may be indented to the item's content.
                if var f = openingFence(i, prefixEnd, end, inList ? 0 : indent) {
                    if f.math {
                        f.prefix = Array(s[i..<prefixEnd])
                        i = end < n ? end + 1 : end
                    } else {
                        out.append(contentsOf: s[i..<end])
                        i = copyNewline(end)
                    }
                    fence = f
                    atLineStart = true
                    previousBlank = false
                    continue
                }

                if isListMarker(prefixEnd, end) {
                    inList = true
                } else if indent == 0 && previousBlank {
                    inList = false
                }
                previousBlank = false
            }

            let c = s[i]
            switch c {
            case newline:
                out.append(c)
                i += 1
                atLineStart = true
            case backslash:
                i = backslashAt(i)
            case dollar:
                i = dollarAt(i)
            case backtick:
                i = backticksAt(i)
            case UInt8(ascii: "<"):
                i = angleAt(i)
            case UInt8(ascii: "]"):
                i = linkTargetAt(i)
            default:
                out.append(c)
                i += 1
            }
        }

        if let f = fence, f.math {
            // An unclosed fence runs to the end of the file, as in CommonMark.
            out.append(contentsOf: f.prefix)
            emit(tex: String(decoding: f.content, as: UTF8.self), display: true,
                 source: String(decoding: s[f.start..<n], as: UTF8.self))
        }
        return ScanResult(markdown: String(decoding: out, as: UTF8.self), math: math, frontMatter: frontMatter)
    }

    // MARK: Lines and blocks

    func lineEnd(_ i: Int) -> Int {
        var j = i
        while j < n && s[j] != newline { j += 1 }
        return j
    }

    mutating func copyNewline(_ end: Int) -> Int {
        if end < n { out.append(newline); return end + 1 }
        return end
    }

    func isBlank(_ from: Int, _ to: Int) -> Bool {
        var j = from
        while j < to {
            if s[j] != space && s[j] != tab { return false }
            j += 1
        }
        return true
    }

    /// Skips block quote markers and returns where the content starts and its indentation in columns.
    func containerPrefix(_ start: Int, _ end: Int) -> (Int, Int) {
        var j = start
        var column = 0
        while true {
            var k = j
            var col = column
            while k < end && (s[k] == space || s[k] == tab) {
                col = s[k] == tab ? (col / 4 + 1) * 4 : col + 1
                k += 1
            }
            if k < end && s[k] == UInt8(ascii: ">") && col - column < 4 {
                j = k + 1
                column = col + 1
                if j < end && s[j] == space { j += 1; column += 1 }
                continue
            }
            return (k, col - column)
        }
    }

    func openingFence(_ lineStart: Int, _ p: Int, _ end: Int, _ indent: Int) -> Fence? {
        guard indent < 4, p < end, s[p] == backtick || s[p] == tilde else { return nil }
        let char = s[p]
        var j = p
        while j < end && s[j] == char { j += 1 }
        let length = j - p
        guard length >= 3 else { return nil }
        let info = String(decoding: s[j..<end], as: UTF8.self).trimmingSpaces()
        if char == backtick && info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return Fence(char: char, length: length, math: language == "math", start: lineStart)
    }

    func isClosingFence(_ p: Int, _ end: Int, _ f: Fence) -> Bool {
        var j = p
        while j < end && s[j] == f.char { j += 1 }
        return j - p >= f.length && isBlank(j, end)
    }

    func isListMarker(_ p: Int, _ end: Int) -> Bool {
        guard p < end else { return false }
        let c = s[p]
        if c == UInt8(ascii: "-") || c == UInt8(ascii: "*") || c == UInt8(ascii: "+") {
            return p + 1 == end || s[p + 1] == space || s[p + 1] == tab
        }
        var j = p
        while j < end && j - p < 9 && s[j] >= 48 && s[j] <= 57 { j += 1 }
        guard j > p, j < end, s[j] == UInt8(ascii: ".") || s[j] == UInt8(ascii: ")") else { return false }
        return j + 1 == end || s[j + 1] == space || s[j + 1] == tab
    }

    /// Whether the line starting at `i` begins a new block, which inline math and code spans must
    /// not run into. A line inside the same block quote as the current one continues its paragraph.
    func startsBlock(_ i: Int) -> Bool {
        let end = lineEnd(i)
        let (p, indent) = containerPrefix(i, end)
        if p == end || isBlank(p, end) { return true }
        if s[i..<p].reduce(0, { $1 == UInt8(ascii: ">") ? $0 + 1 : $0 }) != quoteDepth { return true }
        guard indent < 4 else { return false }
        let c = s[p]
        if c == UInt8(ascii: "#") || c == backtick || c == tilde || c == UInt8(ascii: "|") { return true }
        return isListMarker(p, end)
    }

    // MARK: Front matter

    /// YAML front matter: a --- line at the very top, `key: value` lines, then --- or ... .
    /// A leading horizontal rule followed by ordinary text is left alone.
    mutating func skipFrontMatter() -> Int {
        guard n >= 4, s[0] == UInt8(ascii: "-"), s[1] == UInt8(ascii: "-"), s[2] == UInt8(ascii: "-") else { return 0 }
        let first = lineEnd(0)
        guard isBlank(3, first), first < n else { return 0 }
        let bodyStart = first + 1
        var i = bodyStart
        var sawKey = false
        while i < n {
            let end = lineEnd(i)
            let line = s[i..<end]
            if line.elementsEqual("---".utf8) || line.elementsEqual("...".utf8) {
                guard sawKey else { return 0 }
                frontMatter = String(decoding: s[bodyStart..<max(bodyStart, i - 1)], as: UTF8.self)
                return end < n ? end + 1 : end
            }
            if !sawKey && !isBlank(i, end) {
                // The first line must look like `key:`.
                guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > i else { return 0 }
                let key = s[i..<colon]
                guard key.allSatisfy({ $0 == space || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
                                       || ($0 | 0x20 >= 97 && $0 | 0x20 <= 122) || ($0 >= 48 && $0 <= 57) })
                else { return 0 }
                sawKey = true
            }
            i = end + 1
        }
        return 0
    }

    // MARK: Inline constructs

    mutating func emit(tex: String, display: Bool, source: String) {
        out.append(contentsOf: Placeholder.openBytes)
        out.append(contentsOf: String(math.count).utf8)
        out.append(contentsOf: Placeholder.closeBytes)
        let body = quoteDepth > 0 && tex.contains("\n") ? removingQuoteMarkers(tex, depth: quoteDepth) : tex
        math.append(MathSpan(tex: body, display: display, source: source))
    }

    /// A formula that wraps inside a block quote carries the quote's > markers on its later lines.
    func removingQuoteMarkers(_ tex: String, depth: Int) -> String {
        var lines = tex.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        for k in lines.indices.dropFirst() {
            var line = lines[k]
            for _ in 0..<depth {
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                guard trimmed.first == ">" else { break }
                line = trimmed.dropFirst()
                if line.first == " " { line = line.dropFirst() }
            }
            lines[k] = line
        }
        return lines.joined(separator: "\n")
    }

    func text(_ from: Int, _ to: Int) -> String {
        String(decoding: s[from..<to], as: UTF8.self)
    }

    func isASCIIPunctuation(_ c: UInt8) -> Bool {
        (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
    }

    func isSpace(_ c: UInt8) -> Bool { c == space || c == tab || c == newline }

    /// Searches for `closer` from `from`, skipping backslash pairs. Display math may run over line
    /// breaks until a blank line; inline math also stops before a line that starts a new block.
    mutating func find(_ closer: [UInt8], from: Int, display: Bool) -> Int? {
        let key = display ? closer + [0] : closer
        if let dead = deadEnds[key], dead.from <= from, from < dead.to { return nil }
        var j = from
        while j < n {
            let c = s[j]
            if c == backslash {
                if j + 1 < n && s[j + 1] != newline {
                    if matches(closer, at: j) { return j }
                    j += 2
                    continue
                }
            } else if c == newline {
                let next = j + 1
                if next >= n || isBlank(next, lineEnd(next)) || (!display && startsBlock(next)) {
                    lastStop = next
                    deadEnds[key] = (from, next)
                    return nil
                }
            } else if matches(closer, at: j) {
                return j
            }
            j += 1
        }
        lastStop = n
        deadEnds[key] = (from, n)
        return nil
    }

    func matches(_ pattern: [UInt8], at j: Int) -> Bool {
        guard j + pattern.count <= n else { return false }
        for (k, b) in pattern.enumerated() where s[j + k] != b { return false }
        return true
    }

    mutating func backslashAt(_ i: Int) -> Int {
        guard i + 1 < n else { out.append(backslash); return i + 1 }
        let next = s[i + 1]
        if next == UInt8(ascii: "(") || next == UInt8(ascii: "[") {
            let display = next == UInt8(ascii: "[")
            let closer: [UInt8] = display ? Array("\\]".utf8) : Array("\\)".utf8)
            if let close = find(closer, from: i + 2, display: display) {
                emit(tex: text(i + 2, close), display: display, source: text(i, close + 2))
                return close + 2
            }
        } else if matches(Array("\\begin{".utf8), at: i), let end = environmentEnd(i) {
            emit(tex: text(i, end), display: true, source: text(i, end))
            return end
        }
        // A Markdown escape: keep both characters so the parser sees the same thing.
        if isASCIIPunctuation(next) {
            out.append(backslash)
            out.append(next)
            return i + 2
        }
        out.append(backslash)
        return i + 1
    }

    /// The end of a \begin{env}…\end{env} block for a math environment, if it closes.
    /// One pass matches every \begin{env} it meets against its \end{env} with a stack and
    /// remembers the answers, so later openers (nested or repeated) are looked up, not rescanned.
    mutating func environmentEnd(_ i: Int) -> Int? {
        if let known = environmentEnds[i] { return known }
        if environmentsUnclosed.contains(i) { return nil }
        let nameStart = i + 7
        var j = nameStart
        while j < n && s[j] != UInt8(ascii: "}") && s[j] != newline && j - nameStart < 20 { j += 1 }
        guard j < n, s[j] == UInt8(ascii: "}") else { return nil }
        let name = text(nameStart, j)
        guard mathEnvironments.contains(name) else { return nil }
        let begin = Array("\\begin{\(name)}".utf8)
        let end = Array("\\end{\(name)}".utf8)
        var open = [i]
        var k = j + 1
        while k < n {
            if s[k] == newline {
                let next = k + 1
                if next >= n || isBlank(next, lineEnd(next)) { break }
            } else if matches(end, at: k) {
                environmentEnds[open.removeLast()] = k + end.count
                if open.isEmpty { return k + end.count }
                k += end.count
                continue
            } else if matches(begin, at: k) {
                open.append(k)
                k += begin.count
                continue
            } else if s[k] == backslash {
                k += 2
                continue
            }
            k += 1
        }
        environmentsUnclosed.formUnion(open)
        return environmentEnds[i]
    }

    mutating func dollarAt(_ i: Int) -> Int {
        let next: UInt8? = i + 1 < n ? s[i + 1] : nil
        if next == dollar {
            // $$…$$: display math.
            if let close = find([dollar, dollar], from: i + 2, display: true) {
                let tex = text(i + 2, close)
                if !tex.trimmingSpaces().isEmpty {
                    emit(tex: tex, display: true, source: text(i, close + 2))
                    return close + 2
                }
            }
            out.append(dollar)
            out.append(dollar)
            return i + 2
        }
        if next == backtick {
            // $`…`$: GitLab and GitHub inline math.
            if let close = find([backtick, dollar], from: i + 2, display: false), close > i + 2 {
                emit(tex: text(i + 2, close), display: false, source: text(i, close + 2))
                return close + 2
            }
        } else if let next, !isSpace(next) {
            // $…$: the opening $ is followed by a non-space, and the next unescaped $ closes it if
            // it follows a non-space and is not followed by a digit. Inline math never holds a bare
            // $, so if that one doesn't fit, the opener is a plain dollar sign: prices such as $5
            // and $10 stay text, and "$5, so $x$" keeps its formula.
            if let close = find([dollar], from: i + 1, display: false) {
                let before = s[close - 1]
                let after: UInt8? = close + 1 < n ? s[close + 1] : nil
                if !isSpace(before), after.map({ !($0 >= 48 && $0 <= 57) }) ?? true {
                    emit(tex: text(i + 1, close), display: false, source: text(i, close + 1))
                    return close + 1
                }
            }
        }
        out.append(dollar)
        return i + 1
    }

    mutating func backticksAt(_ i: Int) -> Int {
        var j = i
        while j < n && s[j] == backtick { j += 1 }
        let length = j - i
        let key = [UInt8](repeating: backtick, count: min(length, 64)) + [2]
        if let dead = deadEnds[key], dead.from <= i, i < dead.to {
            out.append(contentsOf: s[i..<j])
            return j
        }
        // Look for a run of exactly the same length; code spans can wrap but not cross a blank line.
        var k = j
        while k < n {
            if s[k] == backtick {
                var e = k
                while e < n && s[e] == backtick { e += 1 }
                if e - k == length {
                    out.append(contentsOf: s[i..<e])
                    return e
                }
                k = e
                continue
            }
            if s[k] == newline {
                let next = k + 1
                if next >= n || isBlank(next, lineEnd(next)) || startsBlock(next) { k = next; break }
            }
            k += 1
        }
        // No closing run: the backticks are literal text, and so is any later run of the same
        // length before the paragraph ends.
        deadEnds[key] = (i, min(k, n))
        out.append(contentsOf: s[i..<j])
        return j
    }

    mutating func angleAt(_ i: Int) -> Int {
        let startsLine = i == lineContentStart
        // HTML comment.
        if matches(Array("<!--".utf8), at: i) {
            if let end = closing(Array("-->".utf8), from: i + 4, block: startsLine) {
                out.append(contentsOf: s[i..<end])
                return end
            }
        }
        // <code>, <pre>, <kbd> and <samp> hold code, like backticks.
        for tag in ["code", "pre", "kbd", "samp"] where matchesTag(tag, at: i) {
            if let end = closing(Array("</\(tag)>".utf8), from: i + 1, block: startsLine && tag == "pre", ignoringCase: true) {
                out.append(contentsOf: s[i..<end])
                return end
            }
        }
        // Autolink: <scheme:…> or <name@host>, no spaces inside.
        var j = i + 1
        while j < n && s[j] != UInt8(ascii: ">") && s[j] != UInt8(ascii: "<") && !isSpace(s[j]) && j - i < 2048 { j += 1 }
        if j < n && s[j] == UInt8(ascii: ">") {
            let inner = s[(i + 1)..<j]
            if inner.contains(UInt8(ascii: ":")) || inner.contains(UInt8(ascii: "@")) {
                out.append(contentsOf: s[i...j])
                return j + 1
            }
        }
        out.append(s[i])
        return i + 1
    }

    /// The end of `closer` after `from`. A block runs to the end of the file if it never closes;
    /// inline HTML must close before the paragraph ends.
    mutating func closing(_ closer: [UInt8], from: Int, block: Bool, ignoringCase: Bool = false) -> Int? {
        let key = closer + [block ? 4 : 3]
        if let dead = deadEnds[key], dead.from <= from, from < dead.to { return nil }
        var j = from
        while j < n {
            if ignoringCase ? matchesIgnoringCase(closer, at: j) : matches(closer, at: j) { return j + closer.count }
            if !block && s[j] == newline {
                let next = j + 1
                if next >= n || isBlank(next, lineEnd(next)) {
                    deadEnds[key] = (from, next)
                    return nil
                }
            }
            j += 1
        }
        if block { return n }
        deadEnds[key] = (from, n)
        return nil
    }

    func matchesTag(_ tag: String, at i: Int) -> Bool {
        let open = Array("<\(tag)".utf8)
        guard matchesIgnoringCase(open, at: i), i + open.count < n else { return false }
        let after = s[i + open.count]
        return after == UInt8(ascii: ">") || isSpace(after)
    }

    func matchesIgnoringCase(_ pattern: [UInt8], at j: Int) -> Bool {
        guard j + pattern.count <= n else { return false }
        for (k, b) in pattern.enumerated() {
            let c = s[j + k]
            let lower = c >= 65 && c <= 90 ? c + 32 : c
            if lower != b { return false }
        }
        return true
    }

    /// `](target)`: copy the link target as is, so a $ in a URL is not taken for math.
    mutating func linkTargetAt(_ i: Int) -> Int {
        out.append(s[i])
        guard i + 1 < n, s[i + 1] == UInt8(ascii: "(") else { return i + 1 }
        var depth = 0
        var j = i + 1
        while j < n && s[j] != newline {
            let c = s[j]
            if c == backslash { j += 2; continue }
            if c == UInt8(ascii: "(") { depth += 1 }
            if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    out.append(contentsOf: s[(i + 1)...j])
                    return j + 1
                }
            }
            j += 1
        }
        return i + 1
    }
}

extension String {
    func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while let f = scalars.first, f == " " || f == "\t" || f == "\n" { scalars.removeFirst() }
        while let l = scalars.last, l == " " || l == "\t" || l == "\n" { scalars.removeLast() }
        return String(scalars)
    }
}
