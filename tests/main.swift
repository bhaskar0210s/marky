// Unit tests for the core: `make test` (built with AddressSanitizer).

import Darwin

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
           file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("\(file):\(line): FAILED \(message())")
    }
}

func equal<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    check(a == b, "\n    got:      \(a)\n    expected: \(b)", file: file, line: line)
}

/// The formulas found in some Markdown, as (tex, display) pairs.
func formulas(_ markdown: String) -> [String] {
    scan(markdown).math.map { ($0.display ? "D:" : "I:") + $0.tex }
}

func token(_ n: Int) -> String { "\u{E000}\(n)\u{E001}" }

// MARK: - Scanner

func testDelimiters() {
    equal(formulas("a $x^2$ b"), ["I:x^2"])
    equal(formulas("a $$x^2$$ b"), ["D:x^2"])
    equal(formulas(#"a \(x_1\) b"#), ["I:x_1"])
    equal(formulas(#"a \[x_1\] b"#), ["D:x_1"])
    equal(formulas(#"\begin{align*}a&=b\\c&=d\end{align*}"#), [#"D:\begin{align*}a&=b\\c&=d\end{align*}"#])
    equal(formulas("a $`x^2`$ b"), ["I:x^2"])
    equal(formulas("```math\nx = 1\ny = 2\n```\n"), ["D:x = 1\ny = 2"])
    equal(formulas("$$\na = b\n$$\n"), ["D:\na = b\n"])
    equal(formulas("~~~math\nx\n~~~"), ["D:x"])
    // The output keeps everything except the formulas.
    equal(scan("a $x$ b").markdown, "a \(token(0)) b")
    equal(scan(#"\(x\) and \[y\]"#).markdown, "\(token(0)) and \(token(1))")
    // The original text is kept for copying.
    equal(scan(#"a \(x\) b"#).math.first?.source, #"\(x\)"#)
}

func testPricesAndEscapes() {
    equal(formulas("It costs $5 and $10."), [])
    equal(formulas("Prices: $5/$10"), [])
    equal(formulas("Pay US$7 or $8"), [])
    equal(formulas(#"Escaped \$x\$ stays"#), [])
    equal(scan(#"Escaped \$x\$ stays"#).markdown, #"Escaped \$x\$ stays"#)
    equal(formulas("$ x $ has spaces"), [])
    equal(formulas("$x$5"), [])
    equal(formulas(#"A literal \\(not math\\)"#), [])
    equal(formulas("Unclosed $$ here"), [])
    equal(scan("Unclosed $$ here").markdown, "Unclosed $$ here")
    equal(formulas(#"$a \$ b$"#), [#"I:a \$ b"#])
    equal(formulas(#"\(a \\ b\)"#), [#"I:a \\ b"#])
}

func testCodeIsLeftAlone() {
    equal(formulas("Use `$x$` here"), [])
    equal(formulas("Use ``a ` $x$`` here"), [])
    equal(formulas("```\n$x$ and \\(y\\)\n```\n$z$"), ["I:z"])
    equal(formulas("~~~\n$x$\n~~~"), [])
    equal(formulas("Para\n\n    $x$ in code\n\nAfter $y$"), ["I:y"])
    equal(formulas("<code>$x$</code> and <!-- $y$ --> and $z$"), ["I:z"])
    equal(formulas("[link](http://a.com/$5$) and <http://b.com/$1$>"), [])
    equal(formulas("Unmatched ` tick and $x$"), ["I:x"])
    // Inside a list, indented lines continue the item rather than starting code.
    equal(formulas("- item\n\n    more $x$"), ["I:x"])
    equal(formulas("1. Step\n   ```\n   $x$\n   ```\n"), [])
}

func testMultiLine() {
    equal(formulas("$a\n\nb$"), [])
    equal(formulas("$a\nb$"), ["I:a\nb"])
    equal(formulas("text $a\n# Heading b$"), [])
    equal(formulas("$$a\n\nb$$"), [])
    equal(formulas("$$\na\n+ b\n$$"), ["D:\na\n+ b\n"])
    // A formula inside a quote loses the quote markers of its later lines.
    equal(formulas("> $$\n> x = 1\n> $$"), ["D:\nx = 1\n"])
    // A math fence inside a list item stays in the item.
    let r = scan("- item\n  ```math\n  x\n  ```\n- next")
    equal(r.markdown, "- item\n  \(token(0))\n- next")
    equal(r.math.first?.tex, "x")
    // Display math inside a list item is replaced in place.
    equal(scan("- a\n  $$\n  x\n  $$\n- b").markdown, "- a\n  \(token(0))\n- b")
}

/// Unmatched delimiters are remembered per paragraph; that must not hide later formulas.
func testManyUnmatched() {
    let prices = (1...300).map { "$\($0)" }.joined(separator: " ")
    equal(formulas(prices + "\n\nThen $x$ here."), ["I:x"])
    equal(formulas("`a `b and $y$ and ``c``"), ["I:y"])
    equal(formulas(#"\(a \(b and \(c\)"#), [#"I:a \(b and \(c"#])
    equal(formulas(#"\begin{align} x \begin{align} y"# + "\n\n" + #"\begin{align}z\end{align}"#), [#"D:\begin{align}z\end{align}"#])
    equal(formulas("$$a\n\n$$b$$"), ["D:b"])
}

/// Cases found in review: each used to lose or mangle a formula.
func testReviewCases() {
    equal(formulas("It costs $5, so $x$ is the price."), ["I:x"])
    equal(formulas("> Let $f(x) = x^2 +\n> 1$ be given."), ["I:f(x) = x^2 +\n1"])
    equal(formulas("> [!NOTE]\n> Wraps \\(a +\n> b\\) here."), ["I:a +\nb"])
    equal(formulas("- Run `make and $x$\n- Use `y`"), ["I:x"])
    equal(formulas("Write <!-- to start. Then $x$."), ["I:x"])
    equal(formulas("<!-- a block\n$y$\n-->\n\n$z$"), ["I:z"])
    equal(formulas("A <code>open and $x$"), ["I:x"])
    equal(formulas("<pre>\n$x$\n\n$y$\n</pre>\n\n$z$"), ["I:z"])
    equal(formulas(#"\begin{pmatrix} to open, e.g. \begin{pmatrix} 1 & 0 \end{pmatrix}"#),
          [#"D:\begin{pmatrix} 1 & 0 \end{pmatrix}"#])
}

func testFrontMatter() {
    let r = scan("---\ntitle: Notes\ntags: [a]\n---\n# Heading $x$")
    equal(r.frontMatter, "title: Notes\ntags: [a]")
    equal(r.markdown, "# Heading \(token(0))")
    // A leading rule followed by ordinary text is not front matter.
    equal(scan("---\n# Heading\n---\nText").frontMatter, nil)
    equal(scan("---\n# Heading\n---\nText").markdown, "---\n# Heading\n---\nText")
}

func testNewlines() {
    equal(formulas("$$\r\na\r\n$$"), ["D:\na\n"])
    equal(scan("a\r\nb\rc").markdown, "a\nb\nc")
}

func testPlaceholderSplit() {
    equal(Placeholder.split("a\(token(3))b"), [.text("a"), .math(3), .text("b")])
    equal(Placeholder.split("x\u{E000}12"), [.text("x\u{E000}12")])
    equal(Placeholder.split("\u{E000}\u{E001}"), [.text("\u{E000}\u{E001}")])
    equal(Placeholder.split("plain"), [.text("plain")])
}

// MARK: - Markdown

func testInlines() {
    let d = parseDocument("Some *em* **strong** `code` [link](https://x.org \"T\") ~~gone~~ ==hi==")
    equal(d.blocks, [.paragraph([
        .text("Some "), .emphasis([.text("em")]), .text(" "), .strong([.text("strong")]), .text(" "),
        .code("code"), .text(" "), .link(destination: "https://x.org", title: "T", content: [.text("link")]),
        .text(" "), .strikethrough([.text("gone")]), .text(" "), .highlight([.text("hi")]),
    ])])
}

func testMathInMarkdown() {
    let d = parseDocument("Let $a_1 * b_2$ be *it*.")
    equal(d.blocks, [.paragraph([.text("Let "), .math(0), .text(" be "), .emphasis([.text("it")]), .text(".")])])
    equal(d.math, [MathSpan(tex: "a_1 * b_2", display: false, source: "$a_1 * b_2$")])

    // Display math in a paragraph becomes a block of its own.
    let e = parseDocument("Before\n$$x$$\nafter")
    equal(e.blocks, [.paragraph([.text("Before")]), .math(0), .paragraph([.text("after")])])

    // Pipes inside a formula do not split table cells.
    let t = parseDocument("| a | b |\n|:--|--:|\n| $|x|$ | 2 |")
    guard case .table(let table)? = t.blocks.first else { return check(false, "no table") }
    equal(table.alignments, [.left, .right])
    equal(table.header, [[.text("a")], [.text("b")]])
    equal(table.rows, [[[.math(0)], [.text("2")]]])
}

func testBlocks() {
    let d = parseDocument("# Title\n\n> quote\n\n---\n\n```swift\nlet x = 1\n```\n")
    equal(d.blocks, [
        .heading(level: 1, content: [.text("Title")]),
        .quote([.paragraph([.text("quote")])]),
        .rule,
        .code(language: "swift", text: "let x = 1\n"),
    ])
}

func testLists() {
    let d = parseDocument("- a\n- [x] done\n- [ ] todo\n\n3. three\n4. four\n")
    equal(d.blocks, [
        .list(List(ordered: false, start: 1, tight: true, items: [
            ListItem(task: nil, blocks: [.paragraph([.text("a")])]),
            ListItem(task: true, blocks: [.paragraph([.text("done")])]),
            ListItem(task: false, blocks: [.paragraph([.text("todo")])]),
        ])),
        .list(List(ordered: true, start: 3, tight: true, items: [
            ListItem(task: nil, blocks: [.paragraph([.text("three")])]),
            ListItem(task: nil, blocks: [.paragraph([.text("four")])]),
        ])),
    ])
    let nested = parseDocument("- outer\n  - inner $x$\n")
    equal(nested.blocks, [.list(List(ordered: false, start: 1, tight: true, items: [
        ListItem(task: nil, blocks: [
            .paragraph([.text("outer")]),
            .list(List(ordered: false, start: 1, tight: true, items: [
                ListItem(task: nil, blocks: [.paragraph([.text("inner "), .math(0)])]),
            ])),
        ]),
    ]))])
}

func testAlertsAndFootnotes() {
    let a = parseDocument("> [!WARNING]\n> Careful $x$\n")
    equal(a.blocks, [.alert(kind: "warning", blocks: [.paragraph([.text("Careful "), .math(0)])])])

    let f = parseDocument("Fact[^1].\n\n[^1]: Source $y$.\n")
    equal(f.blocks, [
        .paragraph([.text("Fact"), .footnoteReference(id: 1, label: "1"), .text(".")]),
        .footnotes([Footnote(id: 1, label: "1", blocks: [.paragraph([.text("Source "), .math(0), .text(".")])])]),
    ])
}

func testOtherSyntax() {
    equal(parseDocument("a &amp; b &copy; &#169; &#xA9; &bogus;").blocks,
          [.paragraph([.text("a & b © © © &bogus;")])])
    equal(parseDocument("See [[Other Note]]").blocks,
          [.paragraph([.text("See "), .wikiLink(target: "Other Note", content: [.text("Other Note")])])])
    equal(parseDocument("---\ntitle: X\n---\nBody").blocks, [.frontMatter("title: X"), .paragraph([.text("Body")])])
    equal(parseDocument("a<br>b").blocks, [.paragraph([.text("a"), .html("<br>"), .text("b")])])
    equal(parseDocument("![alt $x$](img.png)").blocks,
          [.paragraph([.image(source: "img.png", title: "", alt: [.text("alt "), .math(0)])])])
    equal(parseDocument("").blocks, [])
}

func testAnchors() {
    equal(anchorSlug("Hello, World!"), "hello-world")
    equal(anchorSlug("Week 2: Limits & Continuity"), "week-2-limits--continuity")
    equal(anchorSlug("Ünïcode_names-ok"), "ünïcode_names-ok")
    equal(plainText([.text("Area "), .math(0)], math: [MathSpan(tex: "\\pi r^2", display: false, source: "")]),
          "Area \\pi r^2")
}

// MARK: - TeX

func tex(_ s: String, display: Bool = true) -> String {
    var n = TeXNormalizer(symbolCommands: ["≤": "le", "α": "alpha", "→": "to"], commandSymbols: ["alpha": "α"])
    return n.normalize(s, display: display)
}

func testEnvironments() {
    equal(tex(#"\begin{align*}a&=b\\c&=d\end{align*}"#), #"\begin{aligned}a&=b\\c&=d\end{aligned}"#)
    equal(tex(#"\begin{equation}x\label{eq:1}\end{equation}"#), "x")
    equal(tex(#"x\tag{3}"#), #"x\qquad\text{(3)}"#)
    equal(tex(#"\begin{gather}a\\b\end{gather}"#), #"\begin{gathered}a\\b\end{gathered}"#)
    equal(tex(#"\begin{alignat*}{2}a&=b\end{alignat*}"#), #"\begin{alignedat}{2}a&=b\end{alignedat}"#)
    equal(tex(#"\begin{rcases}a\end{rcases}"#), #"\left.\begin{matrix}a\end{matrix}\right\}"#)
}

func testUnicode() {
    equal(tex("y-y₀=m(x-x₀)"), "y-y_{0}=m(x-x_{0})")
    equal(tex("aₙ>0"), "a_{n}>0")
    equal(tex("x²+y¹²"), "x^{2}+y^{12}")
    equal(tex("a ≤ b"), #"a \le  b"#)
    equal(tex("α→β"), #"\alpha \to \text{β}"#)
    equal(tex("3−2"), "3-2")
    equal(tex(#"\text{café ≤}"#), #"\text{café ≤}"#)
    equal(tex("f′(x)"), "f'(x)")
}

func testNegationsAndText() {
    equal(tex(#"a\not=b"#), #"a\neq b"#)
    equal(tex(#"x \not\in A"#), #"x \notin  A"#)
    equal(tex(#"\not\heartsuit"#), #"\cancel{\heartsuit}"#)
    equal(tex(#"f(x)=1\quad\text{on }(a,b)\text{ (and $0$ elsewhere)}"#),
          #"f(x)=1\quad\text{on }(a,b)\text{ (and } 0 \text{ elsewhere)}"#)
    equal(tex(#"\text{a\quad b\,c}"#), "\\text{a\u{2003}b\u{2009}c}")
    equal(tex(#"\mbox{if } x"#), #"\text{if } x"#)
    equal(tex(#"\text{for all \alpha}"#), #"\text{for all α}"#)
}

func testMacros() {
    var n = TeXNormalizer()
    equal(n.normalize(#"\newcommand{\R}{\mathbb{R}} x \in \R^n"#, display: false), #"x \in \mathbb{R}^n"#)
    equal(n.normalize(#"\R"#, display: false), #"\mathbb{R}"#)
    equal(n.normalize(#"\newcommand{\abs}[1]{\left|#1\right|}\abs{x+1}"#, display: false), #"\left|x+1\right|"#)
    equal(n.normalize(#"\def\half{\frac12}\half"#, display: false), #"\frac12"#)
    equal(n.normalize(#"\DeclareMathOperator{\Var}{Var}\Var(X)"#, display: false), #"\operatorname{Var}(X)"#)
    equal(n.normalize(#"\newcommand{\pair}[2][0]{(#1,#2)}\pair{y} \pair[x]{y}"#, display: false), "(0,y) (x,y)")
    // A macro that expands to itself stops instead of hanging.
    let looped = n.normalize(#"\def\a{\a x}\a"#, display: false)
    check(looped.count < 200_000)
}

func testMisc() {
    equal(tex(#"\color{red}{x}"#), #"\color{#E0312E}{x}"#)
    equal(tex(#"\textcolor[HTML]{00FF00}{x}"#), #"\textcolor{#00FF00}{x}"#)
    equal(tex("a % comment\n+ b"), "a + b")
    equal(tex(#"a \% b"#), #"a \% b"#)
    equal(tex(#"a\\b"#), #"\begin{gathered}a\\b\end{gathered}"#)
    equal(tex(#"a&=b\\c&=d"#), #"\begin{aligned}a&=b\\c&=d\end{aligned}"#)
    equal(tex(#"a\\b"#, display: false), #"a\quad b"#)
    equal(tex(#"\begin{aligned}a\\[2pt]b\end{aligned}"#), #"\begin{aligned}a\\b\end{aligned}"#)
    equal(tex(#"\operatorname*{arg\,max}_x"#), #"\operatorname*{arg\,max}_x"#)
    equal(tex(#"a\xrightarrow{u\to 0}b"#), #"a\;\underrightarrow{\scriptstyle\;\;u\to 0\;\;}\;b"#)
    equal(tex(#"a\xRightarrow[n]{f}b"#), #"a\;\underset{\scriptstyle n}{\overset{\scriptstyle f}{\Longrightarrow}}\;b"#)
}

// MARK: - Robustness

/// Random documents built from whole tokens: environments, every delimiter, HTML comments and code
/// tags, quotes and list markers. The scanner, the Markdown tree and the LaTeX rewriting must
/// never crash or loop on them.
func testTokenFuzz() {
    let tokens = [#"\begin{align}"#, #"\end{align}"#, #"\begin{pmatrix}"#, #"\end{pmatrix}"#, "x", "&", #"\\"#,
                  "\n", "\n\n", "$", "$$", #"\("#, #"\)"#, #"\["#, #"\]"#, "`", "``", "<!--", "-->", "<code>",
                  "</code>", "<pre>", "</pre>", "> ", "- ", "1. ", "# ", "| a |", "```math\n", "```\n", " ", "^", "_",
                  #"\frac{"#, "}", "{", #"\text{"#, "€", "₁"]
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<3000 {
        let count = Int.random(in: 0..<40, using: &rng)
        let text = (0..<count).map { _ in tokens.randomElement(using: &rng)! }.joined()
        let d = parseDocument(text)
        for span in d.math { _ = tex(span.tex, display: span.display) }
    }
    check(true)
}

/// Random snippets built from the characters that matter to the scanner must never crash it
/// or lose text outside formulas.
func testFuzz() {
    let alphabet = Array("$\\()[]{}`~*_-+>#|!&<:;^ \n\tabx12é₁")
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<4000 {
        let length = Int.random(in: 0..<60, using: &rng)
        let text = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
        let d = parseDocument(text)
        for span in d.math { _ = tex(span.tex, display: span.display) }
    }
    check(true)
}

testDelimiters()
testPricesAndEscapes()
testCodeIsLeftAlone()
testMultiLine()
testManyUnmatched()
testReviewCases()
testFrontMatter()
testNewlines()
testPlaceholderSplit()
testInlines()
testMathInMarkdown()
testBlocks()
testLists()
testAlertsAndFootnotes()
testOtherSyntax()
testAnchors()
testEnvironments()
testUnicode()
testNegationsAndText()
testMacros()
testMisc()
testFuzz()
testTokenFuzz()

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
if failures > 0 { exit(1) }
