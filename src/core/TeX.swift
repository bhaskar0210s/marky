// Rewrites LaTeX into the dialect the math typesetter reads.
//
// Formulas in Markdown files are written for KaTeX or MathJax, which accept more than the
// typesetter does: amsmath environments such as align*, \newcommand, Unicode symbols typed
// straight into a formula, $…$ inside \text{} and so on. Each rewrite here keeps the meaning
// and maps it onto something the typesetter supports.

public struct TeXNormalizer {
    public struct Macro: Equatable {
        public var arguments: Int
        public var defaultArgument: String?
        public var body: String
    }

    /// Macros defined so far in the document, by name without the backslash.
    public var macros: [String: Macro] = [:]
    /// Commands for Unicode symbols typed into formulas, e.g. "≤" → "le".
    public var symbolCommands: [Unicode.Scalar: String]
    /// The reverse, for symbols written as commands inside \text{}: "alpha" → "α".
    public var commandSymbols: [String: String]

    public init(symbolCommands: [Unicode.Scalar: String] = [:], commandSymbols: [String: String] = [:]) {
        self.symbolCommands = symbolCommands
        self.commandSymbols = commandSymbols
    }

    public mutating func normalize(_ tex: String, display: Bool) -> String {
        var t = Array(tex.unicodeScalars)
        t = removingComments(t)
        t = collectingDefinitions(t)
        if !macros.isEmpty { t = expandingMacros(t) }
        t = rewritingEnvironments(t)
        t = rewritingText(t)
        t = rewritingNot(t)
        t = rewritingArrows(t)
        t = rewritingColors(t)
        t = rewritingUnicode(t)
        t = removingRowSpacing(t)
        t = wrappingLines(t, display: display)
        var result = String(String.UnicodeScalarView(t))
        result = result.trimmingSpaces()
        return result
    }
}

typealias Scalars = [Unicode.Scalar]

private let bs: Unicode.Scalar = "\\"

private func isLetter(_ c: Unicode.Scalar) -> Bool {
    (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
}

private func isSpace(_ c: Unicode.Scalar) -> Bool {
    c == " " || c == "\t" || c == "\n"
}

private extension Array where Element == Unicode.Scalar {
    init(_ string: String) { self = Array(string.unicodeScalars) }

    /// `\name` at i: the name (letters, or one other character) and the index after it.
    func command(at i: Int) -> (name: String, end: Int)? {
        guard i < count, self[i] == bs, i + 1 < count else { return nil }
        var j = i + 1
        if isLetter(self[j]) {
            while j < count && isLetter(self[j]) { j += 1 }
        } else {
            j += 1
        }
        return (String(String.UnicodeScalarView(self[(i + 1)..<j])), j)
    }

    func skippingSpaces(_ i: Int) -> Int {
        var j = i
        while j < count && isSpace(self[j]) { j += 1 }
        return j
    }

    /// A balanced {…} group at i: its contents and the index after the closing brace.
    func group(at i: Int) -> (content: Scalars, end: Int)? {
        guard i < count, self[i] == "{" else { return nil }
        var depth = 0
        var j = i
        while j < count {
            let c = self[j]
            if c == bs { j += 2; continue }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return (Array(self[(i + 1)..<j]), j + 1) }
            }
            j += 1
        }
        return nil
    }

    /// An optional […] argument at i (after spaces).
    func optional(at i: Int) -> (content: Scalars, end: Int)? {
        let j = skippingSpaces(i)
        guard j < count, self[j] == "[" else { return nil }
        var depth = 0
        var k = j
        while k < count {
            let c = self[k]
            if c == bs { k += 2; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "]" && depth == 0 { return (Array(self[(j + 1)..<k]), k + 1) }
            k += 1
        }
        return nil
    }

    /// One macro argument: a group's contents, a command, or a single character.
    func argument(at i: Int) -> (content: Scalars, end: Int)? {
        let j = skippingSpaces(i)
        guard j < count else { return nil }
        if let g = group(at: j) { return g }
        if let c = command(at: j) { return (Array(self[j..<c.end]), c.end) }
        return ([self[j]], j + 1)
    }

    func starts(with s: String, at i: Int) -> Bool {
        var j = i
        for c in s.unicodeScalars {
            guard j < count, self[j] == c else { return false }
            j += 1
        }
        return true
    }
}

extension TeXNormalizer {
    // MARK: Comments

    func removingComments(_ t: Scalars) -> Scalars {
        guard t.contains("%") else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            let c = t[i]
            if c == bs, i + 1 < t.count {
                out.append(c); out.append(t[i + 1]); i += 2; continue
            }
            if c == "%" {
                while i < t.count && t[i] != "\n" { i += 1 }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: Macros

    /// Records \newcommand, \def, \let and \DeclareMathOperator definitions and removes them.
    mutating func collectingDefinitions(_ t: Scalars) -> Scalars {
        guard t.contains(bs) else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i) else { out.append(t[i]); i += 1; continue }
            switch cmd.name {
            case "newcommand", "renewcommand", "providecommand":
                var j = cmd.end
                if j < t.count && t[j] == "*" { j += 1 }
                j = t.skippingSpaces(j)
                // The name: {\foo} or \foo.
                var name: String?
                if let g = t.group(at: j), let c = g.content.command(at: g.content.skippingSpaces(0)) {
                    name = c.name; j = g.end
                } else if let c = t.command(at: j) {
                    name = c.name; j = c.end
                }
                var arguments = 0
                var defaultArgument: String?
                if let n = t.optional(at: j) {
                    arguments = Int(String(String.UnicodeScalarView(n.content)).trimmingSpaces()) ?? 0
                    j = n.end
                    if let d = t.optional(at: j) {
                        defaultArgument = String(String.UnicodeScalarView(d.content))
                        j = d.end
                    }
                }
                j = t.skippingSpaces(j)
                if let name, let body = t.group(at: j) {
                    if cmd.name != "providecommand" || macros[name] == nil {
                        macros[name] = Macro(arguments: min(arguments, 9), defaultArgument: defaultArgument,
                                             body: String(String.UnicodeScalarView(body.content)))
                    }
                    i = body.end
                    continue
                }
            case "def", "gdef", "edef", "xdef":
                if let c = t.command(at: t.skippingSpaces(cmd.end)) {
                    // Parameter text: #1#2… up to the body's brace.
                    var j = c.end
                    var arguments = 0
                    while j < t.count && t[j] != "{" {
                        if t[j] == "#" { arguments += 1 }
                        j += 1
                    }
                    if let body = t.group(at: j) {
                        macros[c.name] = Macro(arguments: min(arguments, 9), defaultArgument: nil,
                                               body: String(String.UnicodeScalarView(body.content)))
                        i = body.end
                        continue
                    }
                }
            case "let":
                var j = t.skippingSpaces(cmd.end)
                if let c = t.command(at: j) {
                    j = t.skippingSpaces(c.end)
                    if j < t.count && t[j] == "=" { j = t.skippingSpaces(j + 1) }
                    if let target = t.command(at: j) {
                        macros[c.name] = Macro(arguments: 0, defaultArgument: nil,
                                               body: String(String.UnicodeScalarView(t[j..<target.end])))
                        i = target.end
                        continue
                    }
                }
            case "DeclareMathOperator":
                var j = cmd.end
                var star = false
                if j < t.count && t[j] == "*" { star = true; j += 1 }
                j = t.skippingSpaces(j)
                var name: String?
                if let g = t.group(at: j), let c = g.content.command(at: g.content.skippingSpaces(0)) {
                    name = c.name; j = g.end
                } else if let c = t.command(at: j) {
                    name = c.name; j = c.end
                }
                j = t.skippingSpaces(j)
                if let name, let text = t.group(at: j) {
                    let body = (star ? "\\operatorname*{" : "\\operatorname{") + String(String.UnicodeScalarView(text.content)) + "}"
                    macros[name] = Macro(arguments: 0, defaultArgument: nil, body: body)
                    i = text.end
                    continue
                }
            default:
                break
            }
            out.append(contentsOf: t[i..<cmd.end])
            i = cmd.end
        }
        return out
    }

    /// Expands the document's macros. Expansion is capped so a recursive definition cannot hang.
    func expandingMacros(_ input: Scalars) -> Scalars {
        var t = input
        var i = 0
        var expansions = 0
        while i < t.count {
            guard let cmd = t.command(at: i) else { i += 1; continue }
            guard let macro = macros[cmd.name], expansions < 2000, t.count < 100_000 else { i = cmd.end; continue }
            var j = cmd.end
            var args: [Scalars] = []
            var remaining = macro.arguments
            if let d = macro.defaultArgument, remaining > 0 {
                if let o = t.optional(at: j) {
                    args.append(o.content); j = o.end
                } else {
                    args.append(Array(d))
                }
                remaining -= 1
            }
            while remaining > 0, let a = t.argument(at: j) {
                args.append(a.content)
                j = a.end
                remaining -= 1
            }
            var body: Scalars = []
            let b = Array(macro.body)
            var k = 0
            while k < b.count {
                if b[k] == "#", k + 1 < b.count {
                    let next = b[k + 1]
                    if next == "#" { body.append("#"); k += 2; continue }
                    if let n = Int(String(next)), n >= 1, n <= args.count {
                        body.append(contentsOf: args[n - 1]); k += 2; continue
                    }
                }
                body.append(b[k])
                k += 1
            }
            // Keep a following letter from running into the expansion.
            if let last = body.last, last.properties.isAlphabetic, j < t.count, isLetter(t[j]) { body.append(" ") }
            t.replaceSubrange(i..<j, with: body)
            expansions += 1
        }
        return t
    }

    // MARK: Environments

    func rewritingEnvironments(_ t: Scalars) -> Scalars {
        guard t.contains(bs) else { return t }
        let renames: [String: String] = [
            "align": "aligned", "align*": "aligned", "flalign": "aligned", "flalign*": "aligned",
            "eqnarray": "aligned", "eqnarray*": "aligned", "alignat": "alignedat", "alignat*": "alignedat",
            "gather": "gathered", "gather*": "gathered", "multline": "gathered", "multline*": "gathered",
            "dcases": "cases", "darray": "array",
        ]
        let dropped: Set<String> = ["equation", "equation*", "displaymath", "math", "subequations"]
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i) else { out.append(t[i]); i += 1; continue }
            switch cmd.name {
            case "begin", "end":
                if let g = t.group(at: t.skippingSpaces(cmd.end)) {
                    let name = String(String.UnicodeScalarView(g.content)).trimmingSpaces()
                    if dropped.contains(name) { i = g.end; continue }
                    if name == "rcases" {
                        out += Array(cmd.name == "begin" ? "\\left.\\begin{matrix}" : "\\end{matrix}\\right\\}")
                        i = g.end
                        continue
                    }
                    if let renamed = renames[name] {
                        out += Array("\\\(cmd.name){\(renamed)}")
                        i = g.end
                        continue
                    }
                }
            case "label", "eqref", "ref":
                if let g = t.group(at: t.skippingSpaces(cmd.end)) {
                    if cmd.name != "label" { out += Array("\\text{(") + g.content + Array(")}") }
                    i = g.end
                    continue
                }
            case "nonumber", "notag":
                i = cmd.end
                continue
            case "tag":
                var j = cmd.end
                var star = false
                if j < t.count && t[j] == "*" { star = true; j += 1 }
                if let g = t.group(at: t.skippingSpaces(j)) {
                    out += Array(star ? "\\qquad\\text{" : "\\qquad\\text{(") + g.content + Array(star ? "}" : ")}")
                    i = g.end
                    continue
                }
            case "intertext", "shortintertext":
                out += Array("\\text")
                i = cmd.end
                continue
            default:
                break
            }
            out.append(contentsOf: t[i..<cmd.end])
            i = cmd.end
        }
        return out
    }

    // MARK: Text

    static let textCommands: Set<String> = [
        "text", "textrm", "textup", "textnormal", "textbf", "textit", "textsf", "texttt", "textmd",
        "mbox", "hbox", "emph", "textsl",
    ]

    /// \text{} bodies: $…$ inside becomes math again, and text-mode commands become characters.
    func rewritingText(_ t: Scalars) -> Scalars {
        guard t.contains(bs) else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i), Self.textCommands.contains(cmd.name),
                  let g = t.group(at: t.skippingSpaces(cmd.end)) else {
                if let cmd = t.command(at: i) {
                    out.append(contentsOf: t[i..<cmd.end]); i = cmd.end
                } else {
                    out.append(t[i]); i += 1
                }
                continue
            }
            let name: String
            switch cmd.name {
            case "mbox", "hbox", "textup", "textnormal", "textmd": name = "text"
            case "emph", "textsl": name = "textit"
            default: name = cmd.name
            }
            // Split the body at $…$ and emit text and math pieces in turn.
            var pieces: [(math: Bool, body: Scalars)] = []
            var current: Scalars = []
            var inMath = false
            var k = 0
            let body = g.content
            while k < body.count {
                if body[k] == bs, k + 1 < body.count, body[k + 1] == "$" {
                    current += ["\\", "$"]; k += 2; continue
                }
                if body[k] == "$" {
                    pieces.append((inMath, current)); current = []
                    inMath.toggle()
                    k += 1
                    continue
                }
                current.append(body[k])
                k += 1
            }
            pieces.append((inMath, current))
            for piece in pieces where !piece.body.isEmpty {
                if piece.math {
                    out += [" "] + piece.body + [" "]
                } else {
                    out += Array("\\\(name){") + plainTextMode(piece.body) + ["}"]
                }
            }
            i = g.end
        }
        return out
    }

    /// Text-mode commands the typesetter does not accept inside \text{}.
    func plainTextMode(_ body: Scalars) -> Scalars {
        guard body.contains(bs) || body.contains("~") else { return body }
        let spaces: [String: String] = [
            ",": "\u{2009}", ";": "\u{2005}", ":": "\u{2005}", "!": "", "quad": "\u{2003}",
            "qquad": "\u{2003}\u{2003}", " ": " ", "enspace": "\u{2002}", "thinspace": "\u{2009}",
            "ldots": "…", "dots": "…", "textellipsis": "…", "textendash": "–", "textemdash": "—",
            "\\": " ", "newline": " ", "textbackslash": "\u{2216}", "textasciitilde": "~",
            "textasciicircum": "^", "LaTeX": "LaTeX", "TeX": "TeX",
        ]
        var out: Scalars = []
        var i = 0
        while i < body.count {
            if body[i] == "~" { out.append("\u{00A0}"); i += 1; continue }
            guard let cmd = body.command(at: i) else { out.append(body[i]); i += 1; continue }
            if let s = spaces[cmd.name] {
                out += Array(s)
                i = cmd.end
                if isLetter(body[i - 1]) { i = body.skippingSpaces(i) }
                continue
            }
            if Self.textCommands.contains(cmd.name), let g = body.group(at: body.skippingSpaces(cmd.end)) {
                out += plainTextMode(g.content)
                i = g.end
                continue
            }
            if isLetter(body[i + 1]), let symbol = commandSymbols[cmd.name] {
                out += Array(symbol)
                i = body.skippingSpaces(cmd.end)
                continue
            }
            out.append(contentsOf: body[i..<cmd.end])
            i = cmd.end
        }
        return out
    }

    // MARK: \not

    static let negations: [String: String] = [
        "=": "neq", "<": "nless", ">": "ngtr", "|": "nmid", "in": "notin", "ni": "notni",
        "le": "nleq", "leq": "nleq", "ge": "ngeq", "geq": "ngeq", "subset": "nsubset", "supset": "nsupset",
        "subseteq": "nsubseteq", "supseteq": "nsupseteq", "equiv": "nequiv", "sim": "nsim", "simeq": "nsimeq",
        "approx": "napprox", "cong": "ncong", "mid": "nmid", "parallel": "nparallel", "exists": "nexists",
        "vdash": "nvdash", "models": "nvDash", "prec": "nprec", "succ": "nsucc", "preceq": "npreceq",
        "succeq": "nsucceq", "leftarrow": "nleftarrow", "rightarrow": "nrightarrow", "to": "nrightarrow",
        "leftrightarrow": "nleftrightarrow", "Leftarrow": "nLeftarrow", "Rightarrow": "nRightarrow",
        "Leftrightarrow": "nLeftrightarrow", "ne": "neq", "neq": "neq",
    ]

    func rewritingNot(_ t: Scalars) -> Scalars {
        guard containsCommand(t, "not") else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i) else { out.append(t[i]); i += 1; continue }
            if cmd.name == "not" {
                let j = t.skippingSpaces(cmd.end)
                if let next = t.command(at: j) {
                    if let negated = Self.negations[next.name] {
                        out += Array("\\\(negated) ")
                    } else {
                        out += Array("\\cancel{") + Array(t[j..<next.end]) + ["}"]
                    }
                    i = next.end
                    continue
                }
                if j < t.count {
                    if let negated = Self.negations[String(t[j])] {
                        out += Array("\\\(negated) ")
                    } else {
                        out += Array("\\cancel{") + [t[j]] + ["}"]
                    }
                    i = j + 1
                    continue
                }
            }
            out.append(contentsOf: t[i..<cmd.end])
            i = cmd.end
        }
        return out
    }

    func containsCommand(_ t: Scalars, _ name: String) -> Bool {
        var i = 0
        while i < t.count {
            if let c = t.command(at: i) {
                if c.name == name { return true }
                i = c.end
            } else {
                i += 1
            }
        }
        return false
    }

    // MARK: Extensible arrows

    /// \xrightarrow[below]{above} and friends. The typesetter has arrows that stretch under some
    /// content (\underrightarrow), so the label sits on top of one, in script size.
    static let stretchyArrows: [String: String] = [
        "xrightarrow": "underrightarrow", "xleftarrow": "underleftarrow", "xleftrightarrow": "underleftrightarrow",
    ]
    static let fixedArrows: [String: String] = [
        "xRightarrow": "Longrightarrow", "xLeftarrow": "Longleftarrow", "xLeftrightarrow": "Longleftrightarrow",
        "xmapsto": "longmapsto", "xhookrightarrow": "hookrightarrow", "xhookleftarrow": "hookleftarrow",
        "xtwoheadrightarrow": "twoheadrightarrow", "xtwoheadleftarrow": "twoheadleftarrow",
        "xrightharpoonup": "rightharpoonup", "xrightharpoondown": "rightharpoondown",
        "xleftharpoonup": "leftharpoonup", "xleftharpoondown": "leftharpoondown",
        "xrightleftharpoons": "rightleftharpoons", "xleftrightharpoons": "leftrightharpoons", "xlongequal": "=",
    ]

    func rewritingArrows(_ t: Scalars) -> Scalars {
        guard t.contains(bs) else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i) else { out.append(t[i]); i += 1; continue }
            let stretchy = Self.stretchyArrows[cmd.name]
            let fixed = Self.fixedArrows[cmd.name]
            guard stretchy != nil || fixed != nil else { out.append(contentsOf: t[i..<cmd.end]); i = cmd.end; continue }
            var j = cmd.end
            var below: Scalars = []
            if let o = t.optional(at: j) { below = o.content; j = o.end }
            var above: Scalars = []
            if let g = t.group(at: t.skippingSpaces(j)) { above = g.content; j = g.end }
            var arrow: Scalars
            if let stretchy {
                arrow = Array("\\\(stretchy){\\scriptstyle\\;\\;") + above + Array("\\;\\;}")
            } else {
                let base = fixed == "=" ? Array("=") : Array("\\\(fixed!)")
                arrow = above.isEmpty ? base : Array("\\overset{\\scriptstyle ") + above + ["}", "{"] + base + ["}"]
            }
            if !below.isEmpty { arrow = Array("\\underset{\\scriptstyle ") + below + ["}", "{"] + arrow + ["}"] }
            out += Array("\\;") + arrow + Array("\\;")
            i = j
        }
        return out
    }

    // MARK: Colours

    static let colorNames: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "E0312E", "green": "21A336", "blue": "2563EB",
        "cyan": "06B6D4", "magenta": "D946EF", "yellow": "EAB308", "orange": "F97316", "purple": "9333EA",
        "violet": "7C3AED", "pink": "EC4899", "brown": "92400E", "gray": "6B7280", "grey": "6B7280",
        "darkgray": "4B5563", "lightgray": "D1D5DB", "teal": "0D9488", "olive": "65A30D", "lime": "84CC16",
        "navy": "1E3A8A", "maroon": "991B1B", "gold": "CA8A04", "silver": "9CA3AF", "aqua": "06B6D4",
        "fuchsia": "D946EF", "indigo": "4F46E5", "darkgreen": "166534", "darkblue": "1E40AF",
        "darkred": "991B1B", "lightblue": "93C5FD", "lightgreen": "86EFAC",
    ]

    func rewritingColors(_ t: Scalars) -> Scalars {
        guard containsCommand(t, "color") || containsCommand(t, "textcolor") || containsCommand(t, "colorbox") else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            guard let cmd = t.command(at: i), ["color", "textcolor", "colorbox"].contains(cmd.name) else {
                if let cmd = t.command(at: i) { out.append(contentsOf: t[i..<cmd.end]); i = cmd.end } else { out.append(t[i]); i += 1 }
                continue
            }
            var j = cmd.end
            var model = ""
            if let o = t.optional(at: j) {
                model = String(String.UnicodeScalarView(o.content)).lowercased()
                j = o.end
            }
            j = t.skippingSpaces(j)
            guard let g = t.group(at: j) else { out.append(contentsOf: t[i..<cmd.end]); i = cmd.end; continue }
            let value = String(String.UnicodeScalarView(g.content)).trimmingSpaces()
            out += Array("\\\(cmd.name){\(Self.hexColor(value, model: model))}")
            i = g.end
        }
        return out
    }

    static func hexColor(_ value: String, model: String) -> String {
        if value.hasPrefix("#") { return value }
        switch model {
        case "html":
            return "#" + value
        case "rgb", "rgb255":
            let parts = value.split(separator: ",").compactMap { Double(String($0).trimmingSpaces()) }
            guard parts.count == 3 else { return "#000000" }
            let scale = model == "rgb" ? 255.0 : 1.0
            return "#" + parts.map { hexByte(Int(($0 * scale).rounded())) }.joined()
        case "gray":
            let g = hexByte(Int(((Double(value) ?? 0) * 255).rounded()))
            return "#" + g + g + g
        default:
            if let hex = colorNames[value.lowercased()] { return "#" + hex }
            if value.count == 6, value.allSatisfy({ $0.isHexDigit }) { return "#" + value }
            return "#000000"
        }
    }

    static func hexByte(_ v: Int) -> String {
        let hex = String(max(0, min(255, v)), radix: 16, uppercase: true)
        return hex.count == 1 ? "0" + hex : hex
    }

    // MARK: Unicode

    static let superscripts: [Unicode.Scalar: Unicode.Scalar] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
        "⁺": "+", "⁻": "-", "⁼": "=", "⁽": "(", "⁾": ")", "ⁿ": "n", "ⁱ": "i", "ᵀ": "T", "′": "\u{2032}",
    ]
    static let subscripts: [Unicode.Scalar: Unicode.Scalar] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        "₊": "+", "₋": "-", "₌": "=", "₍": "(", "₎": ")", "ₐ": "a", "ₑ": "e", "ₒ": "o", "ₓ": "x", "ₕ": "h",
        "ₖ": "k", "ₗ": "l", "ₘ": "m", "ₙ": "n", "ₚ": "p", "ₛ": "s", "ₜ": "t", "ᵢ": "i", "ⱼ": "j", "ᵣ": "r",
        "ᵤ": "u", "ᵥ": "v",
    ]
    static let plainEquivalents: [Unicode.Scalar: String] = [
        "\u{2212}": "-", "\u{00A0}": "~", "\u{2009}": "\\,", "\u{2003}": "\\quad ", "′": "'", "″": "''",
        "‴": "'''", "\u{2018}": "`", "\u{2019}": "'",
    ]

    /// Unicode symbols typed into a formula become commands; sub- and superscript digits become
    /// _{…} and ^{…}. \text{} and \operatorname{} bodies keep their characters.
    func rewritingUnicode(_ t: Scalars) -> Scalars {
        guard t.contains(where: { $0.value > 127 }) else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            if let cmd = t.command(at: i) {
                var j = t.skippingSpaces(cmd.end)
                if cmd.name == "operatorname", j < t.count, t[j] == "*" { j = t.skippingSpaces(j + 1) }
                if Self.textCommands.contains(cmd.name) || cmd.name == "operatorname", let g = t.group(at: j) {
                    out.append(contentsOf: t[i..<g.end])
                    i = g.end
                } else {
                    out.append(contentsOf: t[i..<cmd.end])
                    i = cmd.end
                }
                continue
            }
            let c = t[i]
            if c.value < 128 { out.append(c); i += 1; continue }
            if let marker = Self.superscripts[c] != nil ? "^" : Self.subscripts[c] != nil ? "_" : nil {
                let table = marker == "^" ? Self.superscripts : Self.subscripts
                var run: [String] = []
                while i < t.count, let mapped = table[t[i]] {
                    run.append(mapped == "\u{2032}" ? "\\prime " : String(mapped))
                    i += 1
                }
                out += run == ["\\prime "] ? ["'"] : Array("\(marker){\(run.joined())}")
                continue
            }
            if let plain = Self.plainEquivalents[c] {
                out += Array(plain)
            } else if let name = symbolCommands[c] {
                out += Array("\\\(name) ")
            } else if c.properties.generalCategory != .nonspacingMark {
                // Anything else is shown as a character; a stray combining mark is dropped.
                out += Array("\\text{") + [c] + ["}"]
            }
            i += 1
        }
        return out
    }

    // MARK: Line breaks

    /// \\[2pt] adds space after a line break; the typesetter has no use for the dimension.
    func removingRowSpacing(_ t: Scalars) -> Scalars {
        guard t.contains("[") else { return t }
        var out: Scalars = []
        var i = 0
        while i < t.count {
            if let cmd = t.command(at: i) {
                out.append(contentsOf: t[i..<cmd.end])
                i = cmd.end
                if cmd.name == "\\", let o = t.optional(at: i),
                   o.content.allSatisfy({ $0 == "." || $0 == "-" || $0 == " " || ($0 >= "0" && $0 <= "9") || isLetter($0) }) {
                    i = o.end
                }
                continue
            }
            out.append(t[i])
            i += 1
        }
        return out
    }

    /// \\ outside any environment breaks lines in display math (KaTeX does this). The typesetter
    /// needs an environment for that, so the formula is wrapped in one: aligned when it also
    /// uses &, gathered otherwise. Inline math has no lines to break, so \\ becomes a space there.
    func wrappingLines(_ t: Scalars, display: Bool) -> Scalars {
        var depth = 0
        var envDepth = 0
        var topBreaks: [Range<Int>] = []
        var topAmpersand = false
        var i = 0
        while i < t.count {
            let c = t[i]
            if let cmd = t.command(at: i) {
                if cmd.name == "begin" { envDepth += 1 }
                if cmd.name == "end" { envDepth -= 1 }
                if cmd.name == "\\" && depth == 0 && envDepth == 0 { topBreaks.append(i..<cmd.end) }
                if cmd.name == "newline" && depth == 0 && envDepth == 0 { topBreaks.append(i..<cmd.end) }
                i = cmd.end
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "&" && depth == 0 && envDepth == 0 { topAmpersand = true }
            i += 1
        }
        guard !topBreaks.isEmpty || topAmpersand else { return t }
        var body = t
        if !display {
            for r in topBreaks.reversed() { body.replaceSubrange(r, with: Array("\\quad ")) }
            return body
        }
        for r in topBreaks.reversed() where r.upperBound - r.lowerBound > 2 {
            body.replaceSubrange(r, with: Array("\\\\"))
        }
        let env = topAmpersand ? "aligned" : "gathered"
        return Array("\\begin{\(env)}") + body + Array("\\end{\(env)}")
    }
}
